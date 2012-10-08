#!/bin/sh
# A script to start the kde workspace.
# Written by Michael Jansen and Michael Pyne
#
# You can use it in two ways. Just copy the content to the given path.
#
# 1. $HOME/.xsession
# ------------------
# Select "custom" session when logging in. This will use that script.
#
# 2. $KDEDIRS/bin/mystartkde
# See "files xsession" on how to use that. Make sure the script is executable.
# Note: This doesn't work with kdesrc-build -- mpyne

# === User-modifiable variables. Should be set automatically by kdesrc-build.

# Where KDE libraries and applications are installed to.
kde_prefix="<% kdedir %>"  # E.g. "$HOME/kde-4"

# Where Qt is installed to. If using the system Qt, leave blank or set to
# 'auto' and this script will try to auto-detect.
qt_prefix="<% qtdir %>"    # E.g. "$HOME/qt4" or "/usr" on many systems.

# Directory to use for KDE configuration and other user customizations.
KDEHOME="$HOME/.kde4-self" # Or perhaps "$HOME/.kde-selfmade", etc.

# "Bitness" suffix to use for library directories. If left blank, will try to
# auto-detect from installed KDE's compiled defaults, which may still leave
# this blank.
lib_suffix="" # Or 32, or 64, as appropriate for your system.

# Additional paths to add to PATH, can be left blank.
user_path=""  # Set to colon-separated PATH to add to the Qt/KDE paths.

# If more user customizations to the environment are needed, create a file
# .xsession-local, which will be sourced just prior to running KDE. This can
# read .bashrc, just set a few vars, etc.

# === End of user-modifiable variables.

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
    eval curVal=\$'{'$1'}'

    if [ -n "$curVal" ]; then
        eval "$1"="$2:$curVal";
    else
        eval "$1"="$2"
    fi
}

# Initialize some variables based on Qt and KDE install paths.
# Since this should be run as .xsession there's no guarantee of any
# user-specific variables being set already.
libname="lib$libsuffix"
unset STRIGI_PLUGIN_PATH
unset KDEDIRS

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
path_add "XDG_DATA_DIRS"      "$path/share";
path_add "XDG_CONFIG_DIRS"    "$path/etc/xdg";

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

# Read in user-specific customizations
if test -f "$HOME/.xsession-local"; then
    source "$HOME/.xsession-local"
fi

#
### Start the standard kde login script.
#
"$kde_prefix/bin/startkde"

# If you experience problems on logout it is sometimes helpful to make copies
# of the xsession-errors file on logout.
# cp $HOME/.xsession-errors $HOME/.xsession-errors-`date +"%Y%m%d%H%M"`

# Use user-specific logout if present
if test -f "$HOME/.xsession-logout"; then
    source "$HOME/.xsession-logout"
fi
