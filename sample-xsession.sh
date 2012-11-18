#!/bin/sh
# A script to start the kde workspace.
# Written by Michael Jansen and Michael Pyne
#
# Use by copying this script to ~/.xsession (this will be done for you by
# kdesrc-build and/or kdesrc-build-setup, later).
#
# From there, select "custom" session when logging in, in order to login using
# this script.
#
# If more user customizations to the environment are needed, create a file
# .xsession-local, which will be sourced just prior to running KDE. This can
# read .bashrc, just set a few vars, etc.

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

. "${XDG_CONFIG_HOME}/kde-env-master.sh" # Should be installed by kdesrc-build

# See .kde-env-master.sh for details on the kdesrc-build: filter stuff

if ! test -n "$KDESRC_BUILD_TESTING"; then # kdesrc-build: filter
# Read in user-specific customizations
if test -f "$HOME/.xsession-local"; then
    . "$HOME/.xsession-local"
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
    . "$HOME/.xsession-logout"
fi
fi # kdesrc-build: filter
