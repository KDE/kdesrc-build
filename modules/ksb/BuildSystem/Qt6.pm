package ksb::BuildSystem::Qt6 0.10;

# Class responsible for building Qt6 CMake-based modules.

use warnings;
use v5.22;

use parent qw(ksb::BuildSystem::CMake);

use ksb::BuildContext 0.30;
use ksb::Debug;
use ksb::Util;

use List::Util qw(first);

# OVERRIDE
sub name
{
    return 'Qt6';
}

sub prepareModuleBuildEnvironment
{
    my ($self, $ctx, $module, $prefix) = @_;

    # We're installing Qt6 modules, make sure our Qt directory matches our
    # install prefix so that environment variables are properly set.
    $module->setOption('qtdir', $prefix);

    return $self->SUPER::prepareModuleBuildEnvironment($ctx, $module, $prefix);
}

# Return value style: boolean
sub configureInternal
{
    my $self = shift;
    my $module = $self->module();

    # If we're "qtbase" then we should apply cmake-toolchain, if set. Otherwise
    # we should call Qt's provided qt-configure-module which will call CMake
    # with the appropriate Qt 6 private toolchain.

    if ($module->name() eq 'qtbase') {
        info("Configuring Qt6 qtbase module");
        return $self->SUPER::configureInternal();
    }

    # Use cmake to create the build directory (sh script return value
    # semantics).
    my $srcdir = $module->fullpath('source');
    my @cmake_opts = split(' ', $module->getOption('cmake-options'));
    my $result = log_command($module, 'qt-configure-module', [
            'qt-configure-module', $srcdir, '--', @cmake_opts
        ]);

    return ($result == 0); # $result is sh-style
}

1;
