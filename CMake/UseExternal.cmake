
# Copyright (c) 2012-2014 Stefan.Eilemann@epfl.ch

find_package(Git REQUIRED)
find_package(PkgConfig)
find_package(Subversion)

option(BUILDYARD_UPDATE_REBASE
  "Try to merge fetched updates for project source folders" ON)
option(BUILDYARD_FORCE_BUILD "Force building non-optional projects from source"
  ON)
if(TRAVIS OR BUILDYARD_BOOTSTRAP)
  option(BUILDYARD_BUILD_OPTIONAL "Build optional project dependencies" OFF)
else()
  option(BUILDYARD_BUILD_OPTIONAL "Build optional project dependencies" ON)
endif()

include(CMakeParseArguments)
include(CommonPackage)
include(ExternalProject)
include(LSBInfo)
include(Package)
include(SCM)
include(UseExternalAutoconf)
include(UseExternalDeps)
include(UseExternalMakefile)
include(UseExternalGitClone)

set_property(GLOBAL PROPERTY USE_FOLDERS ON)
file(REMOVE ${CMAKE_BINARY_DIR}/projects.make)

set(USE_EXTERNAL_SUBTARGETS update all only configure test install download
  Makefile stat clean reset resetall projects bootstrap doxygit)
foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
  add_custom_target(${subtarget}s)
  set_target_properties(${subtarget}s PROPERTIES FOLDER "00_Meta")
endforeach()
add_custom_target(build)
set_target_properties(build PROPERTIES FOLDER "00_Main")
add_dependencies(updates update)

add_custom_target(Buildyard-stat
  COMMAND ${GIT_EXECUTABLE} status -s --untracked-files=no
  COMMENT "Buildyard Status:"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  )
set_target_properties(Buildyard-stat
  PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
add_dependencies(stats Buildyard-stat)

# renames existing origin and adds user URL as new origin (git only)
function(USE_EXTERNAL_CHANGE_ORIGIN name ORIGIN_URL USER_URL ORIGIN_RENAME)
  if(ORIGIN_URL AND USER_URL)
    string(TOUPPER ${name} NAME)
    set(CHANGE_ORIGIN ${GIT_EXECUTABLE} remote set-url origin "${USER_URL}")
    set(RM_REMOTE
      ${GIT_EXECUTABLE} remote rm ${ORIGIN_RENAME} || ${GIT_EXECUTABLE} status)
    set(ADD_REMOTE
      ${GIT_EXECUTABLE} remote add ${ORIGIN_RENAME} "${ORIGIN_URL}")

    ExternalProject_Add_Step(${name} change_origin
      COMMAND ${CHANGE_ORIGIN}
      COMMAND ${RM_REMOTE}
      COMMAND ${ADD_REMOTE}
      WORKING_DIRECTORY "${${NAME}_SOURCE}"
      DEPENDERS update
      DEPENDEES download
      ALWAYS 1
    )
  endif()
endfunction()

function(USE_EXTERNAL_MAKE name)
  ExternalProject_Get_Property(${name} binary_dir)

  get_property(cmd_set TARGET ${name} PROPERTY _EP_INSTALL_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_INSTALL_COMMAND)
  else()
    _ep_get_build_command(${name} INSTALL cmd)
  endif()

  add_custom_target(${name}-only
    COMMAND ${cmd}
    COMMENT "Building only ${name}"
    DEPENDS ${name}-bootstrap
    WORKING_DIRECTORY ${binary_dir})
  add_custom_target(${name}-all
    COMMAND ${cmd}
    COMMENT "Dependencies built, building ${name}"
    WORKING_DIRECTORY ${binary_dir})
  add_custom_target(${name}-doxygit
    COMMAND ${cmd} doxygit
    COMMENT "Build and copy doxygen documentation for ${name}"
    WORKING_DIRECTORY ${binary_dir}
    DEPENDS ${name}-only)

  # snapshot module for release builds
  if("${CMAKE_BUILD_TYPE}" STREQUAL "Release")
    add_custom_target(${name}-snapshot_install
      COMMAND ${CMAKE_COMMAND} -DCMAKE_INSTALL_PREFIX=${MODULE_SNAPSHOT_DIR} -P cmake_install.cmake
      COMMENT "Installing snapshot of ${name}"
      DEPENDS ${name}-only
      WORKING_DIRECTORY ${binary_dir}
      )
    add_custom_target(${name}-snapshot
      COMMAND ${cmd} snapshot
      COMMENT "Creating snapshot for ${name}"
      WORKING_DIRECTORY ${binary_dir}
      DEPENDS ${name}-snapshot_install
    )
    set_target_properties(${name}-snapshot_install
      PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
    set_target_properties(${name}-snapshot
      PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
  endif()
  set_target_properties(${name}-only
    PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
endfunction()

function(_ep_add_test_command name)
  ExternalProject_Get_Property(${name} binary_dir)

  get_property(cmd_set TARGET ${name} PROPERTY _EP_TEST_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_TEST_COMMAND)
  else()
    _ep_get_build_command(${name} TEST cmd)
  endif()

  string(REGEX REPLACE "^(.*/)cmake([^/]*)$" "\\1ctest\\2" cmd "${cmd}")
  add_custom_target(${name}-test
    COMMAND ${cmd}
    COMMENT "Testing ${name}"
    WORKING_DIRECTORY ${binary_dir}
    DEPENDS ${name}
    )
endfunction()


function(USE_EXTERNAL name)
  # Searches for an external project.
  # * Searches using common_package taking into account:
  # ** NAME_ROOT CMake and environment variables
  # ** .../share/name/CMake
  # ** Version is read from optional $name.cmake
  # * If no pre-installed package is found, use ExternalProject to
  #   build dependency
  # ** External project settings are read from $name.cmake

  cmake_parse_arguments(USE_EXTERNAL "" "" "COMPONENTS" ${ARGN})
  get_property(_check GLOBAL PROPERTY USE_EXTERNAL_${name})
  if(_check) # tested, be quiet and propagate upwards
    set(BUILDING ${BUILDING} PARENT_SCOPE)
    set(SKIPPING ${SKIPPING} PARENT_SCOPE)
    set(NOTINSTALLED ${NOTINSTALLED} PARENT_SCOPE)
    set(USING ${USING} PARENT_SCOPE)
    return()
  endif()

  string(SUBSTRING ${name} 0 2 SHORT_NAME)
  string(TOUPPER ${SHORT_NAME} SHORT_NAME)
  string(TOUPPER ${name} NAME)
  set(ROOT ${NAME}_ROOT)
  set(ENVROOT $ENV{${ROOT}})
  set(SHORT_ROOT ${SHORT_NAME}_ROOT)
  set(SHORT_ENVROOT $ENV{${SHORT_ROOT}})
  if(NOT ${NAME}_SOURCE)
    set(${NAME}_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/${name}")
  endif()

  # CMake module search path
  if(${${SHORT_ROOT}})
    list(APPEND CMAKE_MODULE_PATH "${${SHORT_ROOT}}/share/${name}/CMake")
  endif()
  if(NOT "${SHORT_ENVROOT}" STREQUAL "")
    list(APPEND CMAKE_MODULE_PATH "${SHORT_ENVROOT}/share/${name}/CMake")
  endif()
  if(${${ROOT}})
    list(APPEND CMAKE_MODULE_PATH "${${ROOT}}/share/${name}/CMake")
  endif()
  if(NOT "${ENVROOT}" STREQUAL "")
    list(APPEND CMAKE_MODULE_PATH "${ENVROOT}/share/${name}/CMake")
  endif()

  list(APPEND CMAKE_MODULE_PATH "${CMAKE_INSTALL_PREFIX}/share/${name}/CMake")
  list(APPEND CMAKE_MODULE_PATH /usr/share/${name}/CMake)
  list(APPEND CMAKE_MODULE_PATH /usr/local/share/${name}/CMake)

  if(BUILDYARD_FORCE_BUILD AND NOT ${NAME}_OPTIONAL AND ${NAME}_REPO_URL)
    set(${NAME}_FORCE_BUILD ON)
  endif()
  if(NOT ${NAME}_FORCE_BUILD)
    if(USE_EXTERNAL_COMPONENTS)
      string(REGEX REPLACE  " " ";" USE_EXTERNAL_COMPONENTS
        ${USE_EXTERNAL_COMPONENTS})
      common_package(${name} ${${NAME}_PACKAGE_VERSION} QUIET
        ${${NAME}_FIND_ARGS} COMPONENTS ${USE_EXTERNAL_COMPONENTS})
    else()
      common_package(${name} ${${NAME}_PACKAGE_VERSION} QUIET
        ${${NAME}_FIND_ARGS})
    endif()
  endif()
  if(${NAME}_FOUND)
    set(${name}_FOUND 1) # compat with Foo_FOUND and FOO_FOUND usage
  endif()
  if(${name}_FOUND)
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name}_FOUND ON)
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    set(USING ${USING} ${name} PARENT_SCOPE)
    return()
  endif()

  unset(${name}_INCLUDE_DIR CACHE)  # some find_package (boost) don't properly
  unset(${NAME}_INCLUDE_DIR CACHE)  # unset and recheck the version on
  unset(${name}_INCLUDE_DIRS CACHE) # subsequent runs if it failed
  unset(${NAME}_INCLUDE_DIRS CACHE)
  unset(${name}_LIBRARY_DIRS CACHE)
  unset(${NAME}_LIBRARY_DIRS CACHE)

  if(NOT ${NAME}_REPO_URL)
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    set(NOTINSTALLED ${NOTINSTALLED} ${name} PARENT_SCOPE)
    return()
  endif()

  # pull in dependent projects first
  add_custom_target(${name}-projects)

  set(DEPENDS)
  set(MISSING)
  set(DEPMODE)
  foreach(_dep ${${NAME}_DEPENDS})
    if(${_dep} STREQUAL "OPTIONAL")
      set(DEPMODE)
    elseif(${_dep} STREQUAL "REQUIRED")
      set(DEPMODE REQUIRED)
    else()
      if("${DEPMODE}" STREQUAL "REQUIRED" OR BUILDYARD_BUILD_OPTIONAL)
        get_property(_check GLOBAL PROPERTY USE_EXTERNAL_${_dep})
        if(NOT _check)
          string(TOUPPER ${_dep} _DEP)
          use_external(${_dep} COMPONENTS ${${NAME}_${_DEP}_COMPONENTS})
        endif()
        get_property(_found GLOBAL PROPERTY USE_EXTERNAL_${_dep}_FOUND)
        if(TARGET ${_dep} AND NOT TARGET ${_dep}-missing)
          list(APPEND DEPENDS ${_dep})
          if("${DEPMODE}" STREQUAL "REQUIRED")
            add_dependencies(${_dep}-projects ${name}-projects ${name}-all)
          endif()
        endif()

        if("${DEPMODE}" STREQUAL "REQUIRED" AND NOT _found)
          set(MISSING "${MISSING} ${_dep}")
        endif()
      endif()
    endif()
  endforeach()
  if(MISSING)
    message(STATUS "Skip ${name}: missing${MISSING}")
    file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/info.cmake
      "Skip ${name}: missing${MISSING}\n")
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    set(SKIPPING ${SKIPPING} ${name} PARENT_SCOPE)
    add_custom_target(${name}-missing # fake target to know that this is missing
      COMMAND fail
      COMMENT "Can't build ${name}: missing${MISSING}")
    add_custom_target(${name} # target to inform  on 'make <project>'
      DEPENDS ${name}-missing)
    return()
  endif()

  # External Project
  set(UPDATE_CMD)
  set(REPO_TYPE ${${NAME}_REPO_TYPE})
  if(NOT REPO_TYPE)
    set(REPO_TYPE git)
  endif()
  string(TOUPPER ${REPO_TYPE} REPO_TYPE)
  set(REPOSITORY ${REPO_TYPE}_REPOSITORY)

  if(REPO_TYPE STREQUAL "GIT-SVN")
    set(REPO_TYPE GIT)
    set(REPO_TAG GIT_TAG)
    set(GIT_SVN "svn")
    set(REPOSITORY ${REPO_TYPE}_REPOSITORY)
    # svn rebase fails with local modifications, ignore
    set(UPDATE_CMD ${GIT_EXECUTABLE} svn rebase || ${GIT_EXECUTABLE} status
      ALWAYS TRUE)
  elseif(REPO_TYPE STREQUAL "GIT")
    set(REPO_TAG GIT_TAG)
    set(REPO_ORIGIN_URL ${${NAME}_REPO_URL})
    set(REPO_USER_URL ${${NAME}_USER_URL})
    set(REPO_ORIGIN_NAME ${${NAME}_ORIGIN_NAME})
    if(NOT ${NAME}_REPO_TAG)
      set(${NAME}_REPO_TAG "master")
    endif()
    if(NOT REPO_ORIGIN_NAME)
      if(REPO_ORIGIN_URL AND REPO_USER_URL)
        set(REPO_ORIGIN_NAME "root")
      else()
        set(REPO_ORIGIN_NAME "origin")
      endif()
    endif()

    set(UPDATE_CMD ${CMAKE_COMMAND}
      -DGIT_EXECUTABLE=${GIT_EXECUTABLE} -DREPO_TAG=${${NAME}_REPO_TAG}
      -DBUILDYARD_UPDATE_REBASE=${BUILDYARD_UPDATE_REBASE}
      -P ${CMAKE_CURRENT_LIST_DIR}/GitUpdate.cmake ALWAYS TRUE)
  elseif(REPO_TYPE STREQUAL "SVN")
    if(NOT SUBVERSION_FOUND)
      message(STATUS "Skip ${name}: missing subversion")
      file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/info.cmake
        "Skip ${name}: missing subversion\n")
      set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
      set(SKIPPING ${SKIPPING} ${name} PARENT_SCOPE)
      return()
    endif()
    set(REPO_TAG SVN_REVISION)
    set(REPO_USERNAME SVN_USERNAME ${${NAME}_REPO_USERNAME})
    # The if statement distinguishes between empty and unset passwords.
    if (DEFINED ${NAME}_REPO_PASSWORD)
      set(REPO_PASSWORD SVN_PASSWORD "${${NAME}_REPO_PASSWORD}")
    endif()
  elseif(REPO_TYPE STREQUAL "FILE")
    set(REPOSITORY URL)
  else()
    message(FATAL_ERROR "Unknown repository type ${REPO_TYPE}")
  endif()
  if(${NAME}_AUTOCONF)
    if(NOT AUTORECONF_EXE)
      message(STATUS "Skip ${name}: missing autoconf")
      file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/info.cmake
        "Skip ${name}: missing autoconf\n")
      set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
      set(SKIPPING ${SKIPPING} ${name} PARENT_SCOPE)
      return()
    endif()
    set(${NAME}_EXTRA ${${NAME}_EXTRA} CONFIGURE_COMMAND ${CMAKE_COMMAND} -P ${name}_configure_cmd.cmake)
  endif()

  if(NOT MODULE_SNAPSHOT_DIR)
    set(MODULE_SNAPSHOT_DIR ${CMAKE_CURRENT_BINARY_DIR}/snapshot)
  endif()

  list(APPEND CMAKE_PREFIX_PATH ${BUILDYARD_INSTALL_PATH} /opt/local)
  list(REMOVE_DUPLICATES CMAKE_PREFIX_PATH)

  set(CACHE_ARGS -DBUILDYARD:BOOL=ON
                 -DENABLE_COVERAGE:STRING=${ENABLE_COVERAGE}
                 -DENABLE_WARN_DEPRECATED:BOOL=${ENABLE_WARN_DEPRECATED}
                 -DCMAKE_INSTALL_PREFIX:PATH=${BUILDYARD_INSTALL_PATH}
                 -DCMAKE_PREFIX_PATH:PATH=${BUILDYARD_INSTALL_PATH}
                 -DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_OSX_ARCHITECTURES}
                 -DCMAKE_OSX_SYSROOT:STRING=${CMAKE_OSX_SYSROOT}
                 # module info comes from config.*/Buildyard.cmake
                 -DMODULE_SW_BASEDIR:INTERNAL=${MODULE_SW_BASEDIR}
                 -DMODULE_MODULEFILES:INTERNAL=${MODULE_MODULEFILES}
                 -DMODULE_SW_CLASS:INTERNAL=${MODULE_SW_CLASS}
                 -DMODULE_SNAPSHOT_DIR:INTERNAL=${MODULE_SNAPSHOT_DIR}
                 -DCOMMON_LIBRARY_TYPE:STRING=${COMMON_LIBRARY_TYPE})

  if(NOT ${NAME}_CMAKE_ARGS MATCHES "CMAKE_BUILD_TYPE")
    list(APPEND CACHE_ARGS -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE})
  endif()

  # Fix find of non-system Boost
  if(NOT "$ENV{BOOST_ROOT}" STREQUAL "" OR NOT "$ENV{BOOST_LIBRARYDIR}" STREQUAL "")
    list(APPEND CACHE_ARGS -DBoost_NO_SYSTEM_PATHS:BOOL=ON)
  endif()

  ExternalProject_Add(${name}
    LIST_SEPARATOR !
    PREFIX "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    SOURCE_DIR "${${NAME}_SOURCE}"
    INSTALL_DIR "${BUILDYARD_INSTALL_PATH}"
    DEPENDS "${DEPENDS}"
    ${REPOSITORY} ${${NAME}_REPO_URL}
    ${REPO_TAG} ${${NAME}_REPO_TAG}
    ${REPO_USERNAME}
    "${REPO_PASSWORD}" # This allows empty passwords
    UPDATE_COMMAND ${UPDATE_CMD}
    CMAKE_ARGS ${${NAME}_CMAKE_ARGS}
    CMAKE_CACHE_ARGS ${CACHE_ARGS}
    TEST_AFTER_INSTALL 1
    ${${NAME}_EXTRA}
    STEP_TARGETS ${USE_EXTERNAL_SUBTARGETS}
   )
  set_target_properties(${name}
    PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)

  use_external_git_clone(${name})
  use_external_make(${name})
  file(APPEND ${CMAKE_BINARY_DIR}/projects.make
    "${name}-%:\n"
    "	@\$(MAKE) -C ${CMAKE_BINARY_DIR} $@\n"
    "${name}_%:\n"
    "	@\$(MAKE) -C ${CMAKE_BINARY_DIR}/${name} $*\n\n"
    )

  if(REPO_TYPE STREQUAL "GIT")
    use_external_change_origin(${name} "${REPO_ORIGIN_URL}" "${REPO_USER_URL}"
                              "${REPO_ORIGIN_NAME}")
    unset(${REPO_ORIGIN_URL} CACHE)
    unset(${REPO_USER_URL} CACHE)
    unset(${REPO_ORIGIN_NAME} CACHE)
  endif()

  # add optional targets: package, stat, reset
  get_property(cmd_set TARGET ${name} PROPERTY _EP_BUILD_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_BUILD_COMMAND)
  else()
    _ep_get_build_command(${name} BUILD cmd)
  endif()

  use_external_makefile(${name})
  use_external_deps(${name})
  use_external_autoconf(${name})
  add_custom_target(${name}-clean
    COMMAND ${cmd} clean
    COMMENT "Cleaning ${name}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    )
  set_target_properties(${name}-clean
    PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)

  if(NOT APPLE)
    set(fakeroot fakeroot)
    if(LSB_DISTRIBUTOR_ID STREQUAL "Ubuntu" AND
        CMAKE_VERSION VERSION_GREATER 2.8.6)
      set(fakeroot) # done by deb generator
    endif()
  endif()

  setup_scm(${name})

  add_custom_target(${name}-stat
    COMMAND ${SCM_STATUS}
    COMMENT "${name} Status:"
    WORKING_DIRECTORY "${${NAME}_SOURCE}"
    )
  set_target_properties(${name}-stat PROPERTIES FOLDER ${name}
    EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
  add_dependencies(stats ${name}-stat)

  add_custom_target(${name}-reset
    COMMAND ${SCM_UNSTAGE}
    COMMAND ${SCM_RESET} .
    COMMAND ${SCM_CLEAN}
    COMMENT "SCM reset on ${name}"
    WORKING_DIRECTORY "${${NAME}_SOURCE}"
    DEPENDS ${name}-download
    )
  set_target_properties(${name}-reset
    PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)

  add_custom_target(${name}-resetall DEPENDS ${name}-reset)
  set_target_properties(${name}-resetall
    PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)

  # bootstrapping
  set(BOOTSTRAPFILE ${CMAKE_CURRENT_BINARY_DIR}/${name}/bootstrap.cmake)
  file(WRITE ${BOOTSTRAPFILE}
    "file(GLOB sourcedir_list ${${NAME}_SOURCE}/*)\n
     list(LENGTH sourcedir_list numsourcefiles)\n
     if(numsourcefiles EQUAL 0)\n
       message(FATAL_ERROR \"No sources for ${name} found. Please run '${name}' to download and configure ${name}.\")\n
     endif()\n
     if(NOT EXISTS \"${CMAKE_CURRENT_BINARY_DIR}/${name}/CMakeCache.txt\" AND\n
        NOT EXISTS \"${CMAKE_CURRENT_BINARY_DIR}/${name}/config.status\")\n
       message(FATAL_ERROR \"${name} not configured. Please build '${name}' to configure ${name}.\")\n
     endif()\n"
  )
  add_custom_target(${name}-bootstrap
    COMMAND ${CMAKE_COMMAND} -P ${BOOTSTRAPFILE})
  set_target_properties(${name}-bootstrap PROPERTIES FOLDER ${name}
    EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON )
  add_dependencies(${name}-all ${name}-bootstrap)
  set_target_properties(${name}-all PROPERTIES FOLDER ${name})

  foreach(_dep ${${NAME}_DEPENDS})
    if(TARGET ${_dep} AND NOT ${_dep}-missing)
      add_dependencies(${name}-resetall ${_dep}-resetall)
      add_dependencies(${name}-all ${_dep}-all)
      if(${CMAKE_BUILD_TYPE} STREQUAL "Release")
        add_dependencies(${name}-snapshot_install ${_dep}-snapshot_install)
      endif()
      set_target_properties(${name}-resetall PROPERTIES FOLDER ${name})
    endif()
  endforeach()

  # disable tests if requested
  if(${NAME}_NOTEST)
    set(${NAME}_NOTESTONLY ON)
    set(${NAME}_NODOXYGIT ON)
  endif()

  foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
    set_target_properties(${name}-${subtarget}
      PROPERTIES EXCLUDE_FROM_ALL ON EXCLUDE_FROM_DEFAULT_BUILD ON)
  endforeach()

  if(${NAME}_OPTIONAL)
    set_target_properties(${name} PROPERTIES _EP_IS_OPTIONAL_PROJECT ON)
  else() # add non-optional sub-targets to meta sub-targets
    foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
      string(TOUPPER ${subtarget} UPPER_SUBTARGET)
      if(NOT ${NAME}_NO${UPPER_SUBTARGET})
        add_dependencies(${subtarget}s ${name}-${subtarget})
      endif()
    endforeach()
    add_dependencies(build ${name})
  endif()

  set_target_properties(${name} PROPERTIES FOLDER "00_Main")
  foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
    set_target_properties(${name}-${subtarget} PROPERTIES FOLDER ${name})
  endforeach()

  package(${name})

  set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
  set_property(GLOBAL PROPERTY USE_EXTERNAL_${name}_FOUND ON)
  set(BUILDING ${BUILDING} ${name} PARENT_SCOPE)
  set(SKIPPING ${SKIPPING} PARENT_SCOPE)
  set(NOTINSTALLED ${NOTINSTALLED} PARENT_SCOPE)
  set(USING ${USING} PARENT_SCOPE)
endfunction()
