!># Build target handling
!>
!> This module handles the construction of the build target list
!> from the sources list (`[[targets_from_sources]]`), the
!> resolution of module-dependencies between build targets
!> (`[[resolve_module_dependencies]]`), and the enumeration of
!> objects required for link targets (`[[resolve_target_linking]]`).
!>
!> A build target (`[[build_target_t]]`) is a file to be generated
!> by the backend (compilation and linking).
!>
!> @note The current implementation is ignorant to the existence of
!> module files (`.mod`,`.smod`). Dependencies arising from modules
!> are based on the corresponding object files (`.o`) only.
!>
!> For more information, please read the documentation for the procedures:
!>
!> - `[[build_target_list]]`
!> - `[[resolve_module_dependencies]]`
!>
!>### Enumerations
!>
!> __Target type:__ `FPM_TARGET_*`
!> Describes the type of build target — determines backend build rules
!>
module fpm_targets
use iso_fortran_env, only: int64
use fpm_error, only: error_t, fatal_error, fpm_stop
use fpm_model
use fpm_compiler, only : compiler_t
use fpm_environment, only: get_os_type, OS_WINDOWS, OS_MACOS
use fpm_filesystem, only: dirname, join_path, canon_path
use fpm_strings, only: string_t, operator(.in.), string_cat, fnv_1a, resize, lower, str_ends_with
use fpm_compiler, only: get_macros
use fpm_sources, only: get_exe_name_with_suffix
use fpm_manifest_preprocess, only: preprocess_config_t
implicit none

private

public FPM_TARGET_UNKNOWN, FPM_TARGET_EXECUTABLE, &
       FPM_TARGET_ARCHIVE, FPM_TARGET_OBJECT, &
       FPM_TARGET_C_OBJECT, FPM_TARGET_CPP_OBJECT, &
       FPM_TARGET_NAME
public build_target_t, build_target_ptr
public targets_from_sources, resolve_module_dependencies
public add_target, add_dependency
public filter_library_targets, filter_executable_targets, filter_modules



!> Target type is unknown (ignored)
integer, parameter :: FPM_TARGET_UNKNOWN = -1
!> Target type is executable
integer, parameter :: FPM_TARGET_EXECUTABLE = 1
!> Target type is library archive
integer, parameter :: FPM_TARGET_ARCHIVE = 2
!> Target type is compiled object
integer, parameter :: FPM_TARGET_OBJECT = 3
!> Target type is c compiled object
integer, parameter :: FPM_TARGET_C_OBJECT = 4
!> Target type is cpp compiled object
integer, parameter :: FPM_TARGET_CPP_OBJECT = 5

!> Wrapper type for constructing arrays of `[[build_target_t]]` pointers
type build_target_ptr

    type(build_target_t), pointer :: ptr => null()

end type build_target_ptr


!> Type describing a generated build target
type build_target_t

    !> File path of build target object relative to cwd
    character(:), allocatable :: output_file

    !> File path of build target object relative to output_dir
    character(:), allocatable :: output_name

    !> File path of output directory
    character(:), allocatable :: output_dir

    !> File path of build log file relative to cwd
    character(:), allocatable :: output_log_file

    !> Name of parent package
    character(:), allocatable :: package_name

    !> Primary source for this build target
    type(srcfile_t), allocatable :: source

    !> Resolved build dependencies
    type(build_target_ptr), allocatable :: dependencies(:)

    !> Target type
    integer :: target_type = FPM_TARGET_UNKNOWN

    !> Native libraries to link against
    type(string_t), allocatable :: link_libraries(:)

    !> Objects needed to link this target
    type(string_t), allocatable :: link_objects(:)

    !> Link flags for this build target
    character(:), allocatable :: link_flags

    !> Compile flags for this build target
    character(:), allocatable :: compile_flags

    !> Flag set when first visited to check for circular dependencies
    logical :: touched = .false.

    !> Flag set if build target is sorted for building
    logical :: sorted = .false.

    !> Flag set if build target will be skipped (not built)
    logical :: skip = .false.

    !> Language features
    type(fortran_features_t) :: features

    !> Targets in the same schedule group are guaranteed to be independent
    integer :: schedule = -1

    !> Previous source file hash
    integer(int64), allocatable :: digest_cached

    !> List of macros
    type(string_t), allocatable :: macros(:)

    !> Version number
    character(:), allocatable :: version
    
    contains
    
        procedure :: is_executable_target

end type build_target_t


contains

!> Target type name
pure function FPM_TARGET_NAME(type) result(msg)
   integer, intent(in) :: type
   character(:), allocatable :: msg

   select case (type)
      case (FPM_TARGET_ARCHIVE);    msg = 'Archive'
      case (FPM_TARGET_CPP_OBJECT); msg = 'C++ object'
      case (FPM_TARGET_C_OBJECT);   msg = 'C Object'
      case (FPM_TARGET_EXECUTABLE); msg = 'Executable'
      case (FPM_TARGET_OBJECT);     msg = 'Object'
      case default;                 msg = 'Unknown'
   end select

end function FPM_TARGET_NAME

!> High-level wrapper to generate build target information
subroutine targets_from_sources(targets,model,prune,error)

    !> The generated list of build targets
    type(build_target_ptr), intent(out), allocatable :: targets(:)

    !> The package model from which to construct the target list
    type(fpm_model_t), intent(inout), target :: model

    !> Enable tree-shaking/pruning of module dependencies
    logical, intent(in) :: prune

    !> Error structure
    type(error_t), intent(out), allocatable :: error

    call build_target_list(targets,model)

    call collect_exe_link_dependencies(targets)

    call resolve_module_dependencies(targets,model%external_modules,error)
    if (allocated(error)) return

    if (prune) then
        call prune_build_targets(targets,root_package=model%package_name)
    end if

    call resolve_target_linking(targets,model)

end subroutine targets_from_sources


!> Constructs a list of build targets from a list of source files
!>
!>### Source-target mapping
!>
!> One compiled object target (`FPM_TARGET_OBJECT`) is generated for each
!> non-executable source file (`FPM_UNIT_MODULE`,`FPM_UNIT_SUBMODULE`,
!>  `FPM_UNIT_SUBPROGRAM`,`FPM_UNIT_CSOURCE`).
!>
!> If any source file has scope `FPM_SCOPE_LIB` (*i.e.* there are library sources)
!> then the first target in the target list will be a library archive target
!> (`FPM_TARGET_ARCHIVE`). The archive target will have a dependency on every
!> compiled object target corresponding to a library source file.
!>
!> One compiled object target (`FPM_TARGET_OBJECT`) and one executable target (`FPM_TARGET_EXECUTABLE`) is
!> generated for each exectuable source file (`FPM_UNIT_PROGRAM`). The exectuble target
!> always has a dependency on the corresponding compiled object target. If there
!> is a library, then the executable target has an additional dependency on the library
!> archive target.
!>
subroutine build_target_list(targets,model)

    !> The generated list of build targets
    type(build_target_ptr), intent(out), allocatable :: targets(:)

    !> The package model from which to construct the target list
    type(fpm_model_t), intent(inout), target :: model

    integer :: i, j, n_source, exe_type
    character(:), allocatable :: exe_dir, compile_flags
    logical :: with_lib

    ! Initialize targets
    allocate(targets(0))

    ! Check for empty build (e.g. header-only lib)
    n_source = sum([(size(model%packages(j)%sources), &
                      j=1,size(model%packages))])

    if (n_source < 1) return

    with_lib = any([((model%packages(j)%sources(i)%unit_scope == FPM_SCOPE_LIB, &
                      i=1,size(model%packages(j)%sources)), &
                      j=1,size(model%packages))])

    if (with_lib) call add_target(targets,package=model%package_name,type = FPM_TARGET_ARCHIVE,&
                            output_name = join_path(&
                                   model%package_name,'lib'//model%package_name//'.a'))

    do j=1,size(model%packages)

        associate(sources=>model%packages(j)%sources)

            do i=1,size(sources)

                if (.not. model%include_tests) then
                    if (sources(i)%unit_scope == FPM_SCOPE_TEST) cycle
                end if

                select case (sources(i)%unit_type)
                case (FPM_UNIT_MODULE,FPM_UNIT_SUBMODULE,FPM_UNIT_SUBPROGRAM,FPM_UNIT_CSOURCE)

                    call add_target(targets,package=model%packages(j)%name,source = sources(i), &
                                type = merge(FPM_TARGET_C_OBJECT,FPM_TARGET_OBJECT,&
                                               sources(i)%unit_type==FPM_UNIT_CSOURCE), &
                                output_name = get_object_name(sources(i)), &
                                features = model%packages(j)%features, &
                                preprocess = model%packages(j)%preprocess, &
                                version = model%packages(j)%version)


                    if (with_lib .and. sources(i)%unit_scope == FPM_SCOPE_LIB) then
                        ! Archive depends on object
                        call add_dependency(targets(1)%ptr, targets(size(targets))%ptr)
                    end if

                case (FPM_UNIT_CPPSOURCE)

                    call add_target(targets,package=model%packages(j)%name,source = sources(i), &
                                type = FPM_TARGET_CPP_OBJECT, &
                                output_name = get_object_name(sources(i)), &
                                preprocess = model%packages(j)%preprocess, &
                                version = model%packages(j)%version)

                    if (with_lib .and. sources(i)%unit_scope == FPM_SCOPE_LIB) then
                        ! Archive depends on object
                        call add_dependency(targets(1)%ptr, targets(size(targets))%ptr)
                    end if

                    !> Add stdc++ as a linker flag. If not already there.
                    if (.not. ("stdc++" .in. model%link_libraries)) then

                        if (get_os_type() == OS_MACOS) then
                            model%link_libraries = [model%link_libraries, string_t("c++")]
                        else
                            model%link_libraries = [model%link_libraries, string_t("stdc++")]
                        end if

                    end if

                case (FPM_UNIT_PROGRAM)

                    if (str_ends_with(lower(sources(i)%file_name), [".c"])) then
                        exe_type = FPM_TARGET_C_OBJECT
                    else if (str_ends_with(lower(sources(i)%file_name), [".cpp", ".cc "])) then
                        exe_type = FPM_TARGET_CPP_OBJECT
                    else    ! Default to a Fortran object
                        exe_type = FPM_TARGET_OBJECT
                    end if

                    call add_target(targets,package=model%packages(j)%name,type = exe_type,&
                                output_name = get_object_name(sources(i)), &
                                source = sources(i), &
                                features = model%packages(j)%features, &
                                preprocess = model%packages(j)%preprocess &
                                )

                    if (sources(i)%unit_scope == FPM_SCOPE_APP) then

                        exe_dir = 'app'

                    else if (sources(i)%unit_scope == FPM_SCOPE_EXAMPLE) then

                        exe_dir = 'example'

                    else

                        exe_dir = 'test'

                    end if

                    call add_target(targets,package=model%packages(j)%name,type = FPM_TARGET_EXECUTABLE,&
                                    link_libraries = sources(i)%link_libraries, &
                                    output_name = join_path(exe_dir,get_exe_name_with_suffix(sources(i))))

                    associate(target => targets(size(targets))%ptr)

                    ! Linker-only flags are necessary on some compilers for codes with non-Fortran main
                    select case (exe_type)
                       case (FPM_TARGET_C_OBJECT)
                            call model%compiler%get_main_flags("c",compile_flags)
                       case (FPM_TARGET_CPP_OBJECT)
                            call model%compiler%get_main_flags("c++",compile_flags)
                       case default
                            compile_flags = ""
                    end select
                    target%compile_flags = target%compile_flags//' '//compile_flags

                    ! Executable depends on object
                    call add_dependency(target, targets(size(targets)-1)%ptr)

                    if (with_lib) then
                        ! Executable depends on library
                        call add_dependency(target, targets(1)%ptr)
                    end if

                    endassociate

                end select

            end do

        end associate

    end do

    contains

    function get_object_name(source) result(object_file)
        ! Generate object target path from source name and model params
        !
        !
        type(srcfile_t), intent(in) :: source
        character(:), allocatable :: object_file

        integer :: i
        character(1), parameter :: filesep = '/'

        object_file = canon_path(source%file_name)

        ! Convert any remaining directory separators to underscores
        i = index(object_file,filesep)
        do while(i > 0)
            object_file(i:i) = '_'
            i = index(object_file,filesep)
        end do

        object_file = join_path(model%package_name,object_file)//'.o'

    end function get_object_name

end subroutine build_target_list


!> Add non-library non-module dependencies for executable targets
!>
!>  Executable targets will link to any non-program non-module source files that
!>   are in the same directory or in a subdirectory.
!>
!>  (Note: Fortran module dependencies are handled separately in
!>    `resolve_module_dependencies` and `resolve_target_linking`.)
!>
subroutine collect_exe_link_dependencies(targets)
    type(build_target_ptr), intent(inout) :: targets(:)

    integer :: i, j
    character(:), allocatable :: exe_source_dir

    ! Add non-module dependencies for executables
    do j=1,size(targets)

        if (targets(j)%ptr%target_type == FPM_TARGET_EXECUTABLE) then

            do i=1,size(targets)

                if (i == j) cycle

                associate(exe => targets(j)%ptr, dep => targets(i)%ptr)

                    exe_source_dir = dirname(exe%dependencies(1)%ptr%source%file_name)

                    if (allocated(dep%source)) then

                        if (dep%source%unit_scope /= FPM_SCOPE_LIB .and. &
                            dep%source%unit_type /= FPM_UNIT_PROGRAM .and. &
                            dep%source%unit_type /= FPM_UNIT_MODULE .and. &
                            index(dirname(dep%source%file_name), exe_source_dir) == 1) then

                            call add_dependency(exe, dep)

                        end if

                    end if

                end associate

            end do

        end if

    end do

end subroutine collect_exe_link_dependencies


!> Allocate a new target and append to target list
subroutine add_target(targets, package, type, output_name, source, link_libraries, &
        & features, preprocess, version)
    type(build_target_ptr), allocatable, intent(inout) :: targets(:)
    character(*), intent(in) :: package
    integer, intent(in) :: type
    character(*), intent(in) :: output_name
    type(srcfile_t), intent(in), optional :: source
    type(string_t), intent(in), optional :: link_libraries(:)
    type(fortran_features_t), intent(in), optional :: features
    type(preprocess_config_t), intent(in), optional :: preprocess
    character(*), intent(in), optional :: version

    integer :: i
    type(build_target_t), pointer :: new_target

    if (.not.allocated(targets)) allocate(targets(0))

    ! Check for duplicate outputs
    do i=1,size(targets)

        if (targets(i)%ptr%output_name == output_name) then

            write(*,*) 'Error while building target list: duplicate output object "',&
                        output_name,'"'
            if (present(source)) write(*,*) ' Source file: "',source%file_name,'"'
            call fpm_stop(1,' ')

        end if

    end do

    allocate(new_target)
    new_target%target_type = type
    new_target%output_name = output_name
    new_target%package_name = package
    if (present(source)) new_target%source = source
    if (present(link_libraries)) new_target%link_libraries = link_libraries
    if (present(features)) new_target%features = features
    if (present(preprocess)) then
        if (allocated(preprocess%macros)) new_target%macros = preprocess%macros
    endif
    if (present(version)) new_target%version = version
    allocate(new_target%dependencies(0))

    targets = [targets, build_target_ptr(new_target)]

end subroutine add_target


!> Add pointer to dependeny in target%dependencies
subroutine add_dependency(target, dependency)
    type(build_target_t), intent(inout) :: target
    type(build_target_t) , intent(in), target :: dependency

    target%dependencies = [target%dependencies, build_target_ptr(dependency)]

end subroutine add_dependency


!> Add dependencies to source-based targets (`FPM_TARGET_OBJECT`)
!> based on any modules used by the corresponding source file.
!>
!>### Source file scoping
!>
!> Source files are assigned a scope of either `FPM_SCOPE_LIB`,
!> `FPM_SCOPE_APP` or `FPM_SCOPE_TEST`. The scope controls which
!> modules may be used by the source file:
!>
!> - Library sources (`FPM_SCOPE_LIB`) may only use modules
!>   also with library scope. This includes library modules
!>   from dependencies.
!>
!> - Executable sources (`FPM_SCOPE_APP`,`FPM_SCOPE_TEST`) may use
!>   library modules (including dependencies) as well as any modules
!>   corresponding to source files in the same directory or a
!>   subdirectory of the executable source file.
!>
!> @warning If a module used by a source file cannot be resolved to
!> a source file in the package of the correct scope, then a __fatal error__
!> is returned by the procedure and model construction fails.
!>
subroutine resolve_module_dependencies(targets,external_modules,error)
    type(build_target_ptr), intent(inout), target :: targets(:)
    type(string_t), intent(in) :: external_modules(:)
    type(error_t), allocatable, intent(out) :: error

    type(build_target_ptr) :: dep

    integer :: i, j

    do i=1,size(targets)

        if (.not.allocated(targets(i)%ptr%source)) cycle

            do j=1,size(targets(i)%ptr%source%modules_used)

                if (targets(i)%ptr%source%modules_used(j)%s .in. targets(i)%ptr%source%modules_provided) then
                    ! Dependency satisfied in same file, skip
                    cycle
                end if

                if (targets(i)%ptr%source%modules_used(j)%s .in. external_modules) then
                    ! Dependency satisfied in system-installed module
                    cycle
                end if

                if (any(targets(i)%ptr%source%unit_scope == &
                    [FPM_SCOPE_APP, FPM_SCOPE_EXAMPLE, FPM_SCOPE_TEST])) then
                    dep%ptr => &
                        find_module_dependency(targets,targets(i)%ptr%source%modules_used(j)%s, &
                                            include_dir = dirname(targets(i)%ptr%source%file_name))
                else
                    dep%ptr => &
                        find_module_dependency(targets,targets(i)%ptr%source%modules_used(j)%s)
                end if

                if (.not.associated(dep%ptr)) then
                    call fatal_error(error, &
                            'Unable to find source for module dependency: "' // &
                            targets(i)%ptr%source%modules_used(j)%s // &
                            '" used by "'//targets(i)%ptr%source%file_name//'"')
                    return
                end if

                call add_dependency(targets(i)%ptr, dep%ptr)

            end do

    end do

end subroutine resolve_module_dependencies

function find_module_dependency(targets,module_name,include_dir) result(target_ptr)
    ! Find a module dependency in the library or a dependency library
    !
    ! 'include_dir' specifies an allowable non-library search directory
    !   (Used for executable dependencies)
    !
    type(build_target_ptr), intent(in), target :: targets(:)
    character(*), intent(in) :: module_name
    character(*), intent(in), optional :: include_dir
    type(build_target_t), pointer :: target_ptr

    integer :: k, l

    target_ptr => NULL()

    do k=1,size(targets)

        if (.not.allocated(targets(k)%ptr%source)) cycle

        do l=1,size(targets(k)%ptr%source%modules_provided)

            if (module_name == targets(k)%ptr%source%modules_provided(l)%s) then
                select case(targets(k)%ptr%source%unit_scope)
                case (FPM_SCOPE_LIB, FPM_SCOPE_DEP)
                    target_ptr => targets(k)%ptr
                    exit
                case default
                    if (present(include_dir)) then
                        if (index(dirname(targets(k)%ptr%source%file_name), include_dir) == 1) then ! source file is within the include_dir or a subdirectory
                            target_ptr => targets(k)%ptr
                            exit
                        end if
                    end if
                end select
            end if

        end do

    end do

end function find_module_dependency


!> Perform tree-shaking to remove unused module targets
subroutine prune_build_targets(targets, root_package)

    !> Build target list to prune
    type(build_target_ptr), intent(inout), allocatable :: targets(:)

    !> Name of root package
    character(*), intent(in) :: root_package

    integer :: i, j, nexec
    type(string_t), allocatable :: modules_used(:)
    logical :: exclude_target(size(targets))
    logical, allocatable :: exclude_from_archive(:)

    if (size(targets) < 1) then
        return
    end if

    nexec = 0
    allocate(modules_used(0))

    ! Enumerate modules used by executables, non-module subprograms and their dependencies
    do i=1,size(targets)

        if (targets(i)%ptr%target_type == FPM_TARGET_EXECUTABLE) then

            nexec = nexec + 1
            call collect_used_modules(targets(i)%ptr)

        elseif (allocated(targets(i)%ptr%source)) then

            if (targets(i)%ptr%source%unit_type == FPM_UNIT_SUBPROGRAM) then

                call collect_used_modules(targets(i)%ptr)

            end if

        end if

    end do

    ! If there aren't any executables, then prune
    !  based on modules used in root package
    if (nexec < 1) then

        do i=1,size(targets)

            if (targets(i)%ptr%package_name == root_package .and. &
                 targets(i)%ptr%target_type /= FPM_TARGET_ARCHIVE) then

                call collect_used_modules(targets(i)%ptr)

            end if

        end do

    end if

    call reset_target_flags(targets)

    exclude_target(:) = .false.

    ! Exclude purely module targets if they are not used anywhere
    do i=1,size(targets)
        associate(target=>targets(i)%ptr)

            if (allocated(target%source)) then
                if (target%source%unit_type == FPM_UNIT_MODULE) then

                    exclude_target(i) = .true.
                    target%skip = .true.

                    do j=1,size(target%source%modules_provided)

                        if (target%source%modules_provided(j)%s .in. modules_used) then

                            exclude_target(i) = .false.
                            target%skip = .false.

                        end if

                    end do

                elseif (target%source%unit_type == FPM_UNIT_SUBMODULE) then
                    ! Remove submodules if their parents are not used

                    exclude_target(i) = .true.
                    target%skip = .true.
                    do j=1,size(target%source%parent_modules)

                        if (target%source%parent_modules(j)%s .in. modules_used) then

                            exclude_target(i) = .false.
                            target%skip = .false.

                        end if

                    end do

                end if
            end if

            ! (If there aren't any executables then we only prune modules from dependencies)
            if (nexec < 1 .and. target%package_name == root_package) then
                exclude_target(i) = .false.
                target%skip = .false.
            end if

        end associate
    end do

    targets = pack(targets,.not.exclude_target)

    ! Remove unused targets from archive dependency list
    if (targets(1)%ptr%target_type == FPM_TARGET_ARCHIVE) then
        associate(archive=>targets(1)%ptr)

            allocate(exclude_from_archive(size(archive%dependencies)))
            exclude_from_archive(:) = .false.

            do i=1,size(archive%dependencies)

                if (archive%dependencies(i)%ptr%skip) then

                    exclude_from_archive(i) = .true.

                end if

            end do

            archive%dependencies = pack(archive%dependencies,.not.exclude_from_archive)

        end associate
    end if

    contains

    !> Recursively collect which modules are actually used
    recursive subroutine collect_used_modules(target)
        type(build_target_t), intent(inout) :: target

        integer :: j, k

        if (target%touched) then
            return
        else
            target%touched = .true.
        end if

        if (allocated(target%source)) then

            ! Add modules from this target and from any of it's children submodules
            do j=1,size(target%source%modules_provided)

                if (.not.(target%source%modules_provided(j)%s .in. modules_used)) then

                    modules_used = [modules_used, target%source%modules_provided(j)]

                end if

                ! Recurse into child submodules
                do k=1,size(targets)
                    if (allocated(targets(k)%ptr%source)) then
                        if (targets(k)%ptr%source%unit_type == FPM_UNIT_SUBMODULE) then
                            if (target%source%modules_provided(j)%s .in. targets(k)%ptr%source%parent_modules) then
                                call collect_used_modules(targets(k)%ptr)
                            end if
                        end if
                    end if
                end do

            end do
        end if

        ! Recurse into dependencies
        do j=1,size(target%dependencies)

            if (target%dependencies(j)%ptr%target_type /= FPM_TARGET_ARCHIVE) then
                call collect_used_modules(target%dependencies(j)%ptr)
            end if

        end do

    end subroutine collect_used_modules

    !> Reset target flags after recursive search
    subroutine reset_target_flags(targets)
        type(build_target_ptr), intent(inout) :: targets(:)

        integer :: i

        do i=1,size(targets)

            targets(i)%ptr%touched = .false.

        end do

    end subroutine reset_target_flags

end subroutine prune_build_targets


!> Construct the linker flags string for each target
!>  `target%link_flags` includes non-library objects and library flags
!>
subroutine resolve_target_linking(targets, model)
    type(build_target_ptr), intent(inout), target :: targets(:)
    type(fpm_model_t), intent(in) :: model

    integer :: i
    character(:), allocatable :: global_link_flags, local_link_flags
    character(:), allocatable :: global_include_flags

    if (size(targets) == 0) return

    global_link_flags = ""
    if (allocated(model%link_libraries)) then
        if (size(model%link_libraries) > 0) then
            global_link_flags = model%compiler%enumerate_libraries(global_link_flags, model%link_libraries)
        end if
    end if

    allocate(character(0) :: global_include_flags)
    if (allocated(model%include_dirs)) then
        if (size(model%include_dirs) > 0) then
            global_include_flags = global_include_flags // &
            & " -I" // string_cat(model%include_dirs," -I")
        end if
    end if

    do i=1,size(targets)

        associate(target => targets(i)%ptr)

            ! If the main program is a C/C++ one, some compilers require additional linking flags, see
            ! https://stackoverflow.com/questions/36221612/p3dfft-compilation-ifort-compiler-error-multiple-definiton-of-main
            ! In this case, compile_flags were already allocated
            if (.not.allocated(target%compile_flags)) allocate(character(len=0) :: target%compile_flags)

            target%compile_flags = target%compile_flags//' '

            select case (target%target_type)
               case (FPM_TARGET_C_OBJECT)
                   target%compile_flags = target%compile_flags//model%c_compile_flags
               case (FPM_TARGET_CPP_OBJECT)
                   target%compile_flags = target%compile_flags//model%cxx_compile_flags
               case default
                   target%compile_flags = target%compile_flags//model%fortran_compile_flags &
                                        & // get_feature_flags(model%compiler, target%features)
            end select

            !> Get macros as flags.
            target%compile_flags = target%compile_flags // get_macros(model%compiler%id, &
                                                            target%macros, &
                                                            target%version)

            if (len(global_include_flags) > 0) then
                target%compile_flags = target%compile_flags//global_include_flags
            end if
            target%output_dir = get_output_dir(model%build_prefix, target%compile_flags)
            target%output_file = join_path(target%output_dir, target%output_name)
            target%output_log_file = join_path(target%output_dir, target%output_name)//'.log'
        end associate

    end do

    call add_include_build_dirs(model, targets)

    do i=1,size(targets)

        associate(target => targets(i)%ptr)
            allocate(target%link_objects(0))

            if (target%target_type == FPM_TARGET_ARCHIVE) then
                global_link_flags = target%output_file // global_link_flags

                call get_link_objects(target%link_objects,target,is_exe=.false.)

                allocate(character(0) :: target%link_flags)

            else if (target%target_type == FPM_TARGET_EXECUTABLE) then

                call get_link_objects(target%link_objects,target,is_exe=.true.)

                local_link_flags = ""
                if (allocated(model%link_flags)) local_link_flags = model%link_flags
                target%link_flags = model%link_flags//" "//string_cat(target%link_objects," ")

                if (allocated(target%link_libraries)) then
                    if (size(target%link_libraries) > 0) then
                        target%link_flags = model%compiler%enumerate_libraries(target%link_flags, target%link_libraries)
                        local_link_flags = model%compiler%enumerate_libraries(local_link_flags, target%link_libraries)
                    end if
                end if

                target%link_flags = target%link_flags//" "//global_link_flags

                target%output_dir = get_output_dir(model%build_prefix, &
                   & target%compile_flags//local_link_flags)
                target%output_file     = join_path(target%output_dir, target%output_name)
                target%output_log_file = join_path(target%output_dir, target%output_name)//'.log'
        end if

        end associate

    end do

contains

    !> Wrapper to build link object list
    !>
    !>  For libraries: just list dependency objects of lib target
    !>
    !>  For executables: need to recursively discover non-library
    !>   dependency objects. (i.e. modules in same dir as program)
    !>
    recursive subroutine get_link_objects(link_objects,target,is_exe)
        type(string_t), intent(inout), allocatable :: link_objects(:)
        type(build_target_t), intent(in) :: target
        logical, intent(in) :: is_exe

        integer :: i
        type(string_t) :: temp_str

        if (.not.allocated(target%dependencies)) return

        do i=1,size(target%dependencies)

            associate(dep => target%dependencies(i)%ptr)

                if (.not.allocated(dep%source)) cycle

                ! Skip library dependencies for executable targets
                !  since the library archive will always be linked
                if (is_exe.and.(dep%source%unit_scope == FPM_SCOPE_LIB)) cycle

                ! Skip if dependency object already listed
                if (dep%output_file .in. link_objects) cycle

                ! Add dependency object file to link object list
                temp_str%s = dep%output_file
                link_objects = [link_objects, temp_str]

                ! For executable objects, also need to include non-library
                !  dependencies from dependencies (recurse)
                if (is_exe) call get_link_objects(link_objects,dep,is_exe=.true.)

            end associate

        end do

    end subroutine get_link_objects

end subroutine resolve_target_linking


subroutine add_include_build_dirs(model, targets)
    type(fpm_model_t), intent(in) :: model
    type(build_target_ptr), intent(inout), target :: targets(:)

    integer :: i
    type(string_t), allocatable :: build_dirs(:)
    type(string_t) :: temp

    allocate(build_dirs(0))
    do i = 1, size(targets)
        associate(target => targets(i)%ptr)
            if (target%target_type /= FPM_TARGET_OBJECT) cycle
            if (target%output_dir .in. build_dirs) cycle
            temp%s = target%output_dir
            build_dirs = [build_dirs, temp]
        end associate
    end do

    do i = 1, size(targets)
        associate(target => targets(i)%ptr)
            if (target%target_type /= FPM_TARGET_OBJECT) cycle

            target%compile_flags = target%compile_flags // &
                " " // model%compiler%get_module_flag(target%output_dir) // &
                " -I" // string_cat(build_dirs, " -I")
        end associate
    end do

end subroutine add_include_build_dirs


function get_output_dir(build_prefix, args) result(path)
    character(len=*), intent(in) :: build_prefix
    character(len=*), intent(in) :: args
    character(len=:), allocatable :: path

    character(len=16) :: build_hash

    write(build_hash, '(z16.16)') fnv_1a(args)
    path = build_prefix//"_"//build_hash
end function get_output_dir


subroutine filter_library_targets(targets, list)
    type(build_target_ptr), intent(in) :: targets(:)
    type(string_t), allocatable, intent(out) :: list(:)

    integer :: i, n

    n = 0
    call resize(list)
    do i = 1, size(targets)
        if (targets(i)%ptr%target_type == FPM_TARGET_ARCHIVE) then
            if (n >= size(list)) call resize(list)
            n = n + 1
            list(n)%s = targets(i)%ptr%output_file
        end if
    end do
    call resize(list, n)
end subroutine filter_library_targets

subroutine filter_executable_targets(targets, scope, list)
    type(build_target_ptr), intent(in) :: targets(:)
    integer, intent(in) :: scope
    type(string_t), allocatable, intent(out) :: list(:)

    integer :: i, n

    n = 0
    call resize(list)
    do i = 1, size(targets)
        if (is_executable_target(targets(i)%ptr, scope)) then
            if (n >= size(list)) call resize(list)
            n = n + 1
            list(n)%s = targets(i)%ptr%output_file
        end if
    end do
    call resize(list, n)
end subroutine filter_executable_targets


elemental function is_executable_target(target_ptr, scope) result(is_exe)
    class(build_target_t), intent(in) :: target_ptr
    integer, intent(in) :: scope
    logical :: is_exe
    is_exe = target_ptr%target_type == FPM_TARGET_EXECUTABLE .and. &
        allocated(target_ptr%dependencies)
    if (is_exe) then
        is_exe = target_ptr%dependencies(1)%ptr%source%unit_scope == scope
    end if
end function is_executable_target


subroutine filter_modules(targets, list)
    type(build_target_ptr), intent(in) :: targets(:)
    type(string_t), allocatable, intent(out) :: list(:)

    integer :: i, j, n

    n = 0
    call resize(list)
    do i = 1, size(targets)
        associate(target => targets(i)%ptr)
            if (.not.allocated(target%source)) cycle
            if (target%source%unit_type == FPM_UNIT_SUBMODULE) cycle
            if (n + size(target%source%modules_provided) >= size(list)) call resize(list)
            do j = 1, size(target%source%modules_provided)
                n = n + 1
                list(n)%s = join_path(target%output_dir, &
                    target%source%modules_provided(j)%s)
            end do
        end associate
    end do
    call resize(list, n)
end subroutine filter_modules


function get_feature_flags(compiler, features) result(flags)
    type(compiler_t), intent(in) :: compiler
    type(fortran_features_t), intent(in) :: features
    character(:), allocatable :: flags

    flags = ""
    if (features%implicit_typing) then
        flags = flags // compiler%get_feature_flag("implicit-typing")
    else
        flags = flags // compiler%get_feature_flag("no-implicit-typing")
    end if

    if (features%implicit_external) then
        flags = flags // compiler%get_feature_flag("implicit-external")
    else
        flags = flags // compiler%get_feature_flag("no-implicit-external")
    end if

    if (allocated(features%source_form)) then
        flags = flags // compiler%get_feature_flag(features%source_form//"-form")
    end if
end function get_feature_flags

end module fpm_targets
