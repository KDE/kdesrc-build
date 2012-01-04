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

install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build DESTINATION ${BIN_INSTALL_DIR})
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build-setup DESTINATION ${BIN_INSTALL_DIR})
install(FILES kdesrc-buildrc.xml DESTINATION ${DATA_INSTALL_DIR}/katepart/syntax)

