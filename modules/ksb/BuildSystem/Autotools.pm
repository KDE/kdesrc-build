package ksb::BuildSystem::Autotools;

# This is a module used to support configuring with autotools.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use List::Util qw(first);

use ksb::Debug;
use ksb::Util;
use ksb::BuildSystem;

our @ISA = ('ksb::BuildSystem');

sub name
{
    return 'autotools';
}

# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::Autotools');
    my $module = $self->module();
    my $sourcedir = $module->fullpath('source');
    my $installdir = $module->installationPath();

    # 'module'-limited option grabbing can return undef, so use //
    # to convert to empty string in that case.
    my @bootstrapOptions = split_quoted_on_whitespace(
        $module->getOption('configure-flags', 'module') // '');

    p_chdir($module->fullpath('build'));

    my $configureCommand = first { -e "$sourcedir/$_" } qw(configure autogen.sh);

    croak_internal("No configure command available") unless $configureCommand;

    return log_command($module, 'configure', [
            "$sourcedir/$configureCommand", "--prefix=$installdir",
            @bootstrapOptions
        ]) == 0;
}

1;
