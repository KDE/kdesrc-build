# SPDX-FileCopyrightText: 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::BuildSystem::Qt6 0.10;

# Class responsible for building Qt6 CMake-based modules.

use ksb;

use parent qw(ksb::BuildSystem::KDECMake);

# OVERRIDE
sub name
{
    return 'Qt6';
}

sub prepareModuleBuildEnvironment ($self, $ctx, $module, $prefix)
{
    # We're installing Qt6 modules, make sure our Qt directory matches our
    # install prefix so that environment variables are properly set.
    $module->setOption('qt-install-dir', $prefix);

    return $self->SUPER::prepareModuleBuildEnvironment($ctx, $module, $prefix);
}

1;
