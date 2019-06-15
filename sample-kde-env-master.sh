#!/bin/sh
#
# This sets the various environment variables needed to start Plasma (or other KDE
# software built by kdesrc-build), or to run programs/build programs/etc. in the
# same environment, ideally without clashing with system-built KDE or Qt.
#
# This should not produce any output in order to make it usable by
# non-interactive scripts.
#
# See also the sample xsession setup script, which requires this file.
#
# Use by copying this script to $XDG_CONFIG_HOME/kde-env-master.sh (this will
# be done for you by kdesrc-build and/or kdesrc-build-setup, later). 99% of the
# time this means ~/.config/kde-env-master.sh
#
# NOTHING IN THIS FILE IS MODIFIABLE, OTHERWISE WARNINGS WILL BE GENERATED
# (instead make your changes in your ~/.bashrc, ~/.bash_profile, or whatever else
# you are using)

# === Load user environment settings (i.e. not set through kdesrc-buildrc)
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CONFIG_HOME

# === Modifiable variables. Should be set automatically by kdesrc-build based
# on kdesrc-buildrc settings. Nothing below this line is user-modifiable!

# The KDESRC_BUILD_TESTING stuff is to allow the script to     # kdesrc-build: filter
# be executable by testsuite. It is filtered from destination. # kdesrc-build: filter
if ! test -n "$KDESRC_BUILD_TESTING"; then                     # kdesrc-build: filter
# Where KDE libraries and applications are installed to.
kde_prefix="<% kdedir %>"  # E.g. "$HOME/kf5"

# Where Qt is installed to. If using the system Qt, leave blank and this script
# will try to auto-detect.
qt_prefix="<% qtdir %>"    # E.g. "$HOME/qt5" or "/usr" on many systems.
else                                                           # kdesrc-build: filter
kde_prefix="$HOME/kf5"                                         # kdesrc-build: filter
qt_prefix="$HOME/qt5"                                          # kdesrc-build: filter
fi                                                             # kdesrc-build: filter

# === End of modifiable variables.

# Default qmake executable if we don't find a better one
qmake=${qt_prefix}/bin/qmake

# Find system Qt5
if test -z "$qt_prefix"; then
    # Find right qmake, look for specific executables first
    for qmake_candidate in qmake-qt5 qmake5; do
        if ${qmake_candidate} --version >/dev/null 2>&1; then
            qmake="$qmake_candidate"
            break;
        fi
    done

    qt_prefix=$(${qmake} -query QT_INSTALL_PREFIX 2>/dev/null)

    test -z "$qt_prefix" && qt_prefix="/usr" # Emergency fallback?
fi

# Add path elements to a colon-separated environment variable,
# taking care not to add extra unneeded colons.
# Should be sh-compatible.
# Can't use function keyword in Busybox-sh
path_add()
{
    eval curVal=\$'{'$1'-}'

    if test -n "$curVal"; then
        eval "$1"="$2:'$curVal'";
    else
        eval "$1"="'$2'"
    fi
}

# Now add the necessary directories, starting with Qt (although we don't add Qt
# if it's system Qt to avoid moving /usr up in the PATH.
# Note that LD_LIBRARY_PATH *should* be extraneous with KF5 and Qt5
if test "x$qt_prefix" != "x/usr"; then
    path_add "PATH"               "$(${qmake} -query QT_INSTALL_BINS 2>/dev/null)";
    path_add "PKG_CONFIG_PATH"    "$(${qmake} -query QT_INSTALL_LIBS 2>/dev/null)/pkgconfig";
fi

# There doesn't seem to be a great way to get this from CMake easily
# but we can reason that if there's a /usr/lib64, there will likely end
# up being a $kde_prefix/lib64 once kdesrc-build gets done installing it
libname=lib
if test -d /usr/lib/x86_64-linux-gnu; then
	libname=lib/x86_64-linux-gnu
elif test -d /usr/lib64; then
	libname=lib64
fi

# Now add KDE-specific paths.
path_add "PATH"               "$kde_prefix/bin";
# For some reason I've seen both of lib and lib64 used.  I think due
# to qmake vs. cmake modules
if test $libname = lib64; then
	path_add "PKG_CONFIG_PATH"    "$kde_prefix/lib64/pkgconfig";
fi
path_add "PKG_CONFIG_PATH"    "$kde_prefix/lib/pkgconfig";
path_add "MANPATH"            "$kde_prefix/share/man";
path_add "CMAKE_PREFIX_PATH"  "$kde_prefix";
path_add "QML2_IMPORT_PATH"   "$kde_prefix/$libname/qml";
path_add "QT_PLUGIN_PATH"     "$kde_prefix/$libname/qt5/plugins" # phonon likes this one
path_add "QT_PLUGIN_PATH"     "$kde_prefix/$libname/plugins"     # others like this more
path_add "LD_LIBRARY_PATH"    "$qt_prefix/lib/"

# For Python bindings support.
path_add "PYTHONPATH"         "$kde_prefix/$libname/site-packages";

# https://standards.freedesktop.org/basedir-spec/basedir-spec-latest.html
path_add "XDG_DATA_DIRS"      "$kde_prefix/share:/usr/share";
path_add "XDG_CONFIG_DIRS"    "$kde_prefix/etc/xdg:/etc/xdg";

# Finally, export the variables.
export CMAKE_PREFIX_PATH
export PATH
export PKG_CONFIG_PATH
export PYTHONPATH
export QML2_IMPORT_PATH
export QT_PLUGIN_PATH
export XDG_DATA_DIRS
export XDG_CONFIG_DIRS
export MANPATH
export LD_LIBRARY_PATH
