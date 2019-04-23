package ksb::BuildSystem::Meson 0.10;

# This is a module used to support configuring with Meson.
# This is required for modules like telepathy-accounts-signon

use strict;
use warnings;
use 5.014;

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

sub name
{
    return 'meson';
}

# Override
# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Meson');
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @setupOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    my $buildDir = $module->fullpath('build');
    p_chdir($module->fullpath('source'));

    return log_command($module, 'meson-setup', [
            'meson', 'setup', $buildDir,
            '--prefix', $installdir,
            @setupOptions,
        ]) == 0;
}

# Override
sub buildInternal
{
    my $self = shift;

    return $self->SUPER::buildInternal('ninja-options');
}

# Override
sub buildCommands
{
    return 'ninja';
}

# Override
sub requiredPrograms
{
    return ('meson', 'ninja');
}

# Override
sub configuredModuleFileName
{
    return 'build.ninja';
}

1;
