# SPDX-FileCopyrightText: 2013 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::ModuleSet::Null 0.10;

# Class: ModuleSet::Null
#
# Used automatically by <Module> to represent the absence of a <ModuleSet> without
# requiring definedness checks.

use ksb;

use parent qw(ksb::ModuleSet);

use ksb::BuildException;

sub new
{
    my $class = shift;
    return bless {}, $class;
}

sub name
{
    return '';
}

sub convertToModules
{
    croak_internal("kdesrc-build should not have made it to this call. :-(");
}

1;
