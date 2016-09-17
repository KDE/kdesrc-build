#!/bin/sh
#
# This is a sample user customization script. Unlike other example environment
# setup files, this one can be modified by the user, and kdesrc-build will not
# warn about it or overwrite it.
#
# This file should be installed to $XDG_CONFIG_HOME/kde-env-user.sh (which
# normally means ~/.config/kde-env-user.sh)
#
# As long as it is found here, the kdesrc-build sample session and environment
# setup scripts will pull in settings from that file first.

### Variables supported by the environment script:

# Directory to use for KDE configuration and other user customizations.
# Syntax uses existing value if set, otherwise sets a different one.
# You can also leave blank, but this risks interfering with system KDE.
KDEHOME="$HOME/.kde4-self"

# "Bitness" suffix to use for library directories. If left blank, will try to
# auto-detect from installed KDE's compiled defaults, which may still leave
# this blank.
lib_suffix="" # Or 32, or 64, as appropriate for your system.
# lib_suffix="32"
# lib_suffix="64"

# Additional paths to add to PATH, can be left blank.
user_path=""  # Set to colon-separated PATH to add to the Qt/KDE paths.

### KDE-specific environment variables:
# KDE supports various environment variables that might be useful for your
# kdesrc-build desktop. See also:
# https://techbase.kde.org/KDE_System_Administration/Environment_Variables

KDE_COLOR_DEBUG=1
export KDE_COLOR_DEBUG # Be sure to "export" variables you set yourself.

# If more user customizations to the environment are needed, you can add them
# here.
