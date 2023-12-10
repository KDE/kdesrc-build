cmake_minimum_required(VERSION 3.16)
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
	find_package(KF6 5.10.0 COMPONENTS DocTools)
	if(KF6_DocTools_FOUND)
	     ecm_optional_add_subdirectory(doc)
	else()
             message(WARNING "Found ECM, but not KF6::DocTools; documentation will not be built")
	endif()
    endif()
else()
    message(WARNING "Did not find extra-cmake-modules; documentation will not be built and install paths will be guessed based on CMake settings.")
    # ECM now sets KDE_INSTALL_DATADIR to PREFIX/share, try to match
    set(KDE_INSTALL_DATADIR  "${CMAKE_INSTALL_PREFIX}/share" CACHE PATH "The parent directory where applications can install their data")
    set(KDE_INSTALL_BINDIR   "${CMAKE_INSTALL_PREFIX}/bin"  CACHE PATH "The install dir for executables")
    set(KDE_INSTALL_METAINFODIR "${KDE_INSTALL_DATADIR}/metainfo" CACHE PATH "AppStream metadata directory")
    set(KDE_INSTALL_ZSHAUTOCOMPLETEDIR "${KDE_INSTALL_DATADIR}/zsh/site-functions" CACHE PATH "Zsh functions and autocompletion definitions")
endif()

set(KDESRC_BUILD_INSTALL_MODULES TRUE CACHE BOOL "Controls whether to install the modules that make up the script. Leave enabled unless running straight from source")
set(KDESRC_BUILD_MODULE_INSTALL_PREFIX "${KDE_INSTALL_DATADIR}/kdesrc-build/modules" CACHE PATH "Prefix to install the component Perl modules to. (This is only an option to allow for installing to vendor_perl or similar)")

if (KDESRC_BUILD_INSTALL_MODULES)
    message(STATUS "Installing component modules to ${KDESRC_BUILD_MODULE_INSTALL_PREFIX}")
    install(DIRECTORY modules/
            DESTINATION ${KDESRC_BUILD_MODULE_INSTALL_PREFIX})
endif()

install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build DESTINATION ${KDE_INSTALL_BINDIR})
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-run DESTINATION ${KDE_INSTALL_BINDIR})

install(PROGRAMS
            ${CMAKE_SOURCE_DIR}/sample-kde-env-master.sh
            ${CMAKE_SOURCE_DIR}/sample-xsession.sh
            ${CMAKE_SOURCE_DIR}/data/build-include/custom-qt5-libs.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/qt5.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-applications.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-common-options.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-extragear.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-frameworks.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-kdepim.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-qt5.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf5-workspace.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/custom-qt6-libs.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/qt6.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-applications.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-common-options.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-extragear.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-frameworks.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-kdepim.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-qt6.ksb
            ${CMAKE_SOURCE_DIR}/data/build-include/kf6-workspace.ksb
    DESTINATION ${KDE_INSTALL_DATADIR}/kdesrc-build)

install(FILES org.kde.kdesrc-build.metainfo.xml DESTINATION ${KDE_INSTALL_METAINFODIR})

install(FILES
        completions/zsh/_kdesrc-build_modules
        completions/zsh/_kdesrc-build
        completions/zsh/_kdesrc-run
    DESTINATION ${KDE_INSTALL_ZSHAUTOCOMPLETEDIR})

if (ECM_FOUND)
    feature_summary(WHAT ALL FATAL_ON_MISSING_REQUIRED_PACKAGES)
endif()
