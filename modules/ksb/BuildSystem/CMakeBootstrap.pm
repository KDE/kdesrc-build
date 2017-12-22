package ksb::BuildSystem::CMakeBootstrap 0.10;

# This is a module used to do only one thing: Bootstrap CMake onto a system
# that doesn't have it, or has only an older version of it.

use strict;
use warnings;
use 5.014;

use parent qw(ksb::BuildSystem);

use ksb::Debug;
use ksb::Util;

sub name
{
    return 'cmake-bootstrap';
}

sub requiredPrograms
{
    return qw{c++};
}

# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::CMakeBootstrap');
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @bootstrapOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    p_chdir($module->fullpath('build'));

    return log_command($module, 'cmake-bootstrap', [
            "$sourcedir/bootstrap", "--prefix=$installdir",
            @bootstrapOptions
        ]) == 0;
}

1;
