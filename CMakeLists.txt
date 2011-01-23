cmake_minimum_required(VERSION 2.6) # Pretty much nothing works without this
project(kdesrc-build)

find_package(KDE4 REQUIRED) # Needed for the docs

include(KDE4Defaults)
include(MacroLibrary)

# CMake installs to $KDEDIR/share/doc/HTML/$lang/doc for some reason instead
# of                $KDEDIR/share/doc/HTML/$lang/kdesrc-build.
# Figure it out later I guess...
#macro_optional_add_subdirectory(doc)

# Null install target so CMake succeeds
add_custom_target(install
    COMMAND /bin/true
    )
