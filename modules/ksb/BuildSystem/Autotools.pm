package ksb::BuildSystem::Autotools 0.10;

# This is a module used to support configuring with autotools.

use ksb;

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

use List::Util qw(first);

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

    my $configureCommand = first { -e "$sourcedir/$_" } qw(configure autogen.sh);

    my $configureInFile = first { -e "$sourcedir/$_" } qw(configure.in configure.ac);

    # If we have a configure.in or configure.ac but configureCommand is autogen.sh
    # we assume that configure is created by autogen.sh as usual in some GNU Projects.
    # So we run autogen.sh first to create the configure command and
    # recheck for that.
    if ($configureInFile && $configureCommand eq 'autogen.sh')
    {
        p_chdir($sourcedir);
        my $err = log_command($module, 'autogen', ["$sourcedir/$configureCommand"]);
        return 0 if $err != 0;

        # We don't want a Makefile in the srcdir, so run make-distclean if that happened
        # ... and hope that is enough to fix it
        if (-e "$sourcedir/Makefile") {
            $err = log_command($module, 'distclean', [qw(make distclean)]);
            return 0 if $err != 0;
        }

        # Now recheck
        $configureCommand = first { -e "$sourcedir/$_" } qw(configure autogen.sh);
    }

    croak_internal("No configure command available") unless $configureCommand;

    p_chdir($module->fullpath('build'));

    return log_command($module, 'configure', [
            "$sourcedir/$configureCommand", "--prefix=$installdir",
            @bootstrapOptions
        ]) == 0;
}

1;
