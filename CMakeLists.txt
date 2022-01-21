cmake_minimum_required(VERSION 3.0)
project(kdesrc-build)

include(FeatureSummary)

# Needed for the docs, but optional. If not found, we will simply
# defer to native CMake handling.
find_package(ECM 5.10.0 NO_MODULE QUIET)

if (ECM_FOUND)
    set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

    include(KDEInstallDirs)
    include(KDECMakeSettings)
    include(ECMOptionalAddSubdirectory)

    find_package(KF5 5.10.0 COMPONENTS DocTools)

    if(KF5_DocTools_FOUND)
        ecm_optional_add_subdirectory(doc)
    else()
        message(WARNING "Found ECM, but not KF5::DocTools; documentation will not be built")
    endif()
else()
    message(WARNING "Did not find extra-cmake-modules; documentation will not be built and install paths will be guessed based on CMake settings.")
    # ECM now sets KDE_INSTALL_DATADIR to PREFIX/share, try to match
    set(KDE_INSTALL_DATADIR  "${CMAKE_INSTALL_PREFIX}/share" CACHE PATH "The parent directory where applications can install their data")
    set(KDE_INSTALL_BINDIR   "${CMAKE_INSTALL_PREFIX}/bin"  CACHE PATH "The install dir for executables")
    set(KDE_INSTALL_METAINFODIR "${KDE_INSTALL_DATADIR}/metainfo" CACHE PATH "AppStream metadata directory")
endif()

set(KDESRC_BUILD_INSTALL_MODULES TRUE CACHE BOOL "Controls whether to install the modules that make up the script. Leave enabled unless running straight from source")
set(KDESRC_BUILD_MODULE_INSTALL_PREFIX "${KDE_INSTALL_DATADIR}/kdesrc-build/modules" CACHE PATH "Prefix to install the component Perl modules to. (This is only an option to allow for installing to vendor_perl or similar)")

if (KDESRC_BUILD_INSTALL_MODULES)
    message(STATUS "Installing component modules to ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}")
    install(FILES
        modules/ksb.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX})

    install(FILES
        modules/ksb/Application.pm
        modules/ksb/BuildContext.pm
        modules/ksb/BuildException.pm
        modules/ksb/BuildSystem.pm
        modules/ksb/Debug.pm
        modules/ksb/DebugOrderHints.pm
        modules/ksb/DependencyResolver.pm
        modules/ksb/FirstRun.pm
        modules/ksb/IPC.pm
        modules/ksb/KDEProjectsReader.pm
        modules/ksb/Module.pm
        modules/ksb/ModuleResolver.pm
        modules/ksb/ModuleSet.pm
        modules/ksb/OptionsBase.pm
        modules/ksb/OSSupport.pm
        modules/ksb/PhaseList.pm
        modules/ksb/RecursiveFH.pm
        modules/ksb/StatusView.pm
        modules/ksb/Updater.pm
        modules/ksb/Util.pm
        modules/ksb/Version.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb)

    install(FILES
        modules/ksb/BuildSystem/Autotools.pm
        modules/ksb/BuildSystem/Meson.pm
        modules/ksb/BuildSystem/CMakeBootstrap.pm
        modules/ksb/BuildSystem/KDECMake.pm
        modules/ksb/BuildSystem/QMake.pm
        modules/ksb/BuildSystem/Qt4.pm
        modules/ksb/BuildSystem/Qt5.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/BuildSystem)

    install(FILES
        modules/ksb/Module/BranchGroupResolver.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/Module)

    install(FILES
        modules/ksb/ModuleSet/KDEProjects.pm
        modules/ksb/ModuleSet/Null.pm
        modules/ksb/ModuleSet/Qt.pm
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
        modules/ksb/Updater/Qt5.pm
    DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}/ksb/Updater)
endif()

install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build DESTINATION ${KDE_INSTALL_BINDIR})
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build-setup DESTINATION ${KDE_INSTALL_BINDIR})
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-run DESTINATION ${KDE_INSTALL_BINDIR})

install(PROGRAMS
            ${CMAKE_SOURCE_DIR}/sample-kde-env-master.sh
            ${CMAKE_SOURCE_DIR}/sample-xsession.sh
            ${CMAKE_SOURCE_DIR}/custom-qt5-libs-build-include
            ${CMAKE_SOURCE_DIR}/qt5-build-include
            ${CMAKE_SOURCE_DIR}/kf5-applications-build-include
            ${CMAKE_SOURCE_DIR}/kf5-common-options-build-include
            ${CMAKE_SOURCE_DIR}/kf5-extragear-build-include
            ${CMAKE_SOURCE_DIR}/kf5-frameworks-build-include
            ${CMAKE_SOURCE_DIR}/kf5-kdepim-build-include
            ${CMAKE_SOURCE_DIR}/kf5-qt5-build-include
            ${CMAKE_SOURCE_DIR}/kf5-workspace-build-include
            ${CMAKE_SOURCE_DIR}/kf6-applications-build-include
            ${CMAKE_SOURCE_DIR}/kf6-qt6-build-include
            ${CMAKE_SOURCE_DIR}/kf6-frameworks-build-include
            ${CMAKE_SOURCE_DIR}/kf6-workspace-build-include
	    ${CMAKE_SOURCE_DIR}/kf6-kdepim-build-include
	    ${CMAKE_SOURCE_DIR}/custom-qt6-libs-build-include
    DESTINATION ${KDE_INSTALL_DATADIR}/kdesrc-build)

install(FILES org.kde.kdesrc-build.metainfo.xml DESTINATION ${KDE_INSTALL_METAINFODIR})

if (ECM_FOUND)
    feature_summary(WHAT ALL FATAL_ON_MISSING_REQUIRED_PACKAGES)
endif()
