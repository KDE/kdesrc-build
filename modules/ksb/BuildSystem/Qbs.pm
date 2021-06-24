package ksb::BuildSystem::Qbs 0.10;

# This is a module used to support configuring with Qbs.
# This is required for modules like Tok

use strict;
use warnings;
use 5.014;

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

sub name
{
    return 'qbs';
}

# Override
# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Qbs');
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @setupOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    my $buildDir = $module->fullpath('build');
    p_chdir($module->fullpath('source'));

    return log_command($module, 'qbs-setup', [
            'qbs', 'resolve', '-d', $buildDir,
            'qbs.installPrefix:', $installdir,
            @setupOptions,
        ]) == 0;
}

# Override
sub buildInternal
{
    my $self = shift;

    return $self->SUPER::buildInternal('qbs-options');
}

# Override
sub buildCommands
{
    return 'qbs';
}

# Override
sub requiredPrograms
{
    return ('qbs');
}

# Override
sub configuredModuleFileName
{
    return '/dev/null';
}

1;
