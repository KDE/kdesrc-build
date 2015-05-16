cmake_minimum_required(VERSION 2.6) # Pretty much nothing works without this
project(kdesrc-build)

find_package(KDE4) # Needed for the docs, but optional.

if (KDE4_FOUND)
  include(KDE4Defaults)
  include(MacroLibrary)
  macro_optional_add_subdirectory(doc)
else()
   set(DATA_INSTALL_DIR  "${CMAKE_INSTALL_PREFIX}/share/apps" CACHE PATH "The parent directory where applications can install their data")
   set(BIN_INSTALL_DIR   "${CMAKE_INSTALL_PREFIX}/bin"  CACHE PATH "The install dir for executables")
endif()

set(KDESRC_BUILD_INSTALL_MODULES TRUE CACHE BOOL "Controls whether to install the modules that make up the script. Leave enabled unless running straight from source")
set(KDESRC_BUILD_MODULE_INSTALL_PREFIX "${DATA_INSTALL_DIR}/kdesrc-build/modules" CACHE PATH "Prefix to install the component Perl modules to. (This is only an option to allow for installing to vendor_perl or similar)")

if (KDESRC_BUILD_INSTALL_MODULES)
    message(STATUS "Installing component modules to ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}")
    install(FILES
        modules/ksb/Application.pm
        modules/ksb/BuildContext.pm
        modules/ksb/BuildException.pm
        modules/ksb/BuildSystem.pm
        modules/ksb/Debug.pm
        modules/ksb/DependencyResolver.pm
        modules/ksb/IPC.pm
        modules/ksb/KDEXMLReader.pm
        modules/ksb/Module.pm
        modules/ksb/ModuleSet.pm
        modules/ksb/OptionsBase.pm
        modules/ksb/PhaseList.pm
        modules/ksb/RecursiveFH.pm
        modules/ksb/Updater.pm
        modules/ksb/Util.pm
        modules/ksb/Version.pm
        modules/ksb/l10nSystem.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb)

    install(FILES
        modules/ksb/BuildSystem/Autotools.pm
        modules/ksb/BuildSystem/CMakeBootstrap.pm
        modules/ksb/BuildSystem/KDE4.pm
        modules/ksb/BuildSystem/QMake.pm
        modules/ksb/BuildSystem/Qt4.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/BuildSystem)

    install(FILES
        modules/ksb/Module/BranchGroupResolver.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/Module)

    install(FILES
        modules/ksb/ModuleSet/KDEProjects.pm
        modules/ksb/ModuleSet/Null.pm
        modules/ksb/ModuleSet/KDEDependencyIncluder.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/ModuleSet)

    install(FILES
        modules/ksb/IPC/Null.pm
        modules/ksb/IPC/Pipe.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/IPC)

    install(FILES
        modules/ksb/Updater/Bzr.pm
        modules/ksb/Updater/Git.pm
        modules/ksb/Updater/KDEProject.pm
        modules/ksb/Updater/KDEProjectMetadata.pm
        modules/ksb/Updater/Svn.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/Updater)
endif()

install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build DESTINATION ${BIN_INSTALL_DIR})
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build-setup DESTINATION ${BIN_INSTALL_DIR})
