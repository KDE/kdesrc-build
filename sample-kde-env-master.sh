#!/bin/sh
#
# This sets the various environment variables needed to start a KDE desktop
# built by kdesrc-build, or to run programs/build programs/etc. in the same
# environment.
#
# This should not produce any output in order to make it usable by
# non-interactive scripts.
#
# See also the sample xsession setup script which requires this file.
#
# Use by copying this script to ~/.kde-env-master (this will be done for you by
# kdesrc-build and/or kdesrc-build-setup, later).
#
# NOTHING IN THIS FILE IS MODIFIABLE, OTHERWISE WARNINGS WILL BE GENERATED

# === Load user environment settings (i.e. not set through kdesrc-buildrc)

# ALL USER MODS GO HERE ↴
if test -f "$HOME/.kde-env-user.sh"; then
    . "$HOME/.kde-env-user.sh"
fi

# === Modifiable variables. Should be set automatically by kdesrc-build based
# on kdesrc-buildrc settings. Nothing below this line is user-modifiable!

# kdesrc-build: filter | The KDESRC_BUILD_TESTING stuff is to allow the script to
# kdesrc-build: filter | be executable by testsuite. It is filtered from destination.
if ! test -n "$KDESRC_BUILD_TESTING"; then # kdesrc-build: filter
# Where KDE libraries and applications are installed to.
kde_prefix="<% kdedir %>"  # E.g. "$HOME/kde-4"

# Where Qt is installed to. If using the system Qt, leave blank or set to
# 'auto' and this script will try to auto-detect.
qt_prefix="<% qtdir %>"    # E.g. "$HOME/qt4" or "/usr" on many systems.
else # kdesrc-build: filter
kde_prefix="$HOME/kde"     # kdesrc-build: filter
qt_prefix="$HOME/qt4"      # kdesrc-build: filter
fi # kdesrc-build: filter

# === End of modifiable variables.

# Set defaults if these are unset or null. ':' is a null command
: ${lib_suffix:=""}
: ${user_path:=""}
: ${KDEHOME:="$HOME/.kde4-self"}

# Find system Qt
if test -z "$qt_prefix"; then
    # Find right qmake
    for qmake_candidate in qmake-qt4 qmake4 qmake; do
        if ${qmake_candidate} --version >/dev/null 2>&1; then
            qmake="$qmake_candidate"
            break;
        fi
    done

    qt_prefix=$(${qmake} -query QT_INSTALL_PREFIX 2>/dev/null)

    test -z "$qt_prefix" && qt_prefix="/usr" # Emergency fallback?

    echo "Using Qt found in $qt_prefix"
fi

# Try to auto-determine lib suffix if not set. This requires KDE to already
# have been installed though.
if test -z "$lib_suffix" && test -x "$kde_prefix/bin/kde4-config"; then
    lib_suffix=$("$kde_prefix/bin/kde4-config" --libsuffix 2>/dev/null)
fi

# Add path elements to a colon-separated environment variable,
# taking care not to add extra unneeded colons.
# Should be sh-compatible.
# Can't use function keyword in Busybox-sh
path_add()
{
    eval curVal=\$'{'$1'-}'

    if [ -n "$curVal" ]; then
        eval "$1"="$2:$curVal";
    else
        eval "$1"="$2"
    fi
}

# Initialize some variables based on Qt and KDE install paths.
# Since this should be run as .xsession there's no guarantee of any
# user-specific variables being set already.
libname="lib$lib_suffix"

# Now add the necessary directories, starting with Qt.
path_add "PATH"               "$qt_prefix/bin";
path_add "LD_LIBRARY_PATH"    "$qt_prefix/$libname";
path_add "PKG_CONFIG_PATH"    "$qt_prefix/$libname/pkgconfig";
path_add "MANPATH"            "$qt_prefix/share/man";

# Now add KDE-specific paths.
path_add "PATH"               "$kde_prefix/bin";
path_add "LD_LIBRARY_PATH"    "$kde_prefix/$libname";
path_add "PKG_CONFIG_PATH"    "$kde_prefix/$libname/pkgconfig";
path_add "MANPATH"            "$kde_prefix/share/man";
path_add "CMAKE_PREFIX_PATH"  "$kde_prefix";
path_add "KDEDIRS"            "$kde_prefix";
path_add "QML_IMPORT_PATH"    "$kde_prefix/$libname/kde4/imports";
path_add "STRIGI_PLUGIN_PATH" "$kde_prefix/$libname/strigi";

# For Python bindings support.
path_add "PYTHONPATH"         "$kde_prefix/$libname/site-packages";

# http://standards.freedesktop.org/basedir-spec/basedir-spec-latest.html
path_add "XDG_DATA_DIRS"      "$kde_prefix/share";
path_add "XDG_CONFIG_DIRS"    "$kde_prefix/etc/xdg";

#
### Some Convenience stuff
#
if test -n "$user_path"; then
    path_add "PATH" "$user_path"
fi

test -d "$HOME/local/bin" && path_add "PATH"    "$HOME/local/bin"
test -d "$HOME/local/man" && path_add "MANPATH" "$HOME/local/man"

# Finally, export the variables.
export CMAKE_PREFIX_PATH
export KDEDIRS
export LD_LIBRARY_PATH
export PATH
export PKG_CONFIG_PATH
export PYTHONPATH
export QML_IMPORT_PATH
export STRIGI_PLUGIN_PATH
export XDG_DATA_DIRS
export XDG_CONFIG_DIRS
export MANPATH
export KDEHOME

if ! test -e "$KDEHOME"; then
    mkdir -p "$KDEHOME" >/dev/null 2>&1
fi
