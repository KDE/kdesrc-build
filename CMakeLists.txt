cmake_minimum_required(VERSION 2.6) # Pretty much nothing works without this
project(kdesrc-build)

find_package(KDE4 REQUIRED) # Needed for the docs

include(KDE4Defaults)
include(MacroLibrary)

macro_optional_add_subdirectory(doc)

install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/kdesrc-build DESTINATION ${BIN_INSTALL_DIR})
