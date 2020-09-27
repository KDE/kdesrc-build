package ksb::BuildSystem::QMake 0.10;

# A build system used to build modules that use qmake

use strict;
use warnings;
use v5.22;

use parent qw(ksb::BuildSystem);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

use List::Util qw(first);

sub name
{
    return 'qmake';
}

sub requiredPrograms
{
    return qw{qmake};
}

# Returns the absolute path to 'qmake'. Note the actual executable name may
# not necessarily be 'qmake' as some distributions rename it to allow for
# co-installability with Qt 3 (and 5...)
# If no suitable qmake can be found, undef is returned.
# This is a "static class method" i.e. use ksb::BuildSystem::QMake::absPathToQMake()
sub absPathToQMake
{
    my @possibilities = qw/qmake qmake4 qmake-qt4 qmake-mac qmake-qt5/;
    return first { absPathToExecutable($_) } @possibilities;
}

# Return value style: boolean
sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::BuildSystem::QMake');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');
    my $sourcedir = $self->needsBuilddirHack()
            ? $builddir
            : $module->fullpath('source');

    my @qmakeOpts = split(' ', $module->getOption('qmake-options'));
    my @projectFiles = glob("$sourcedir/*.pro");

    @projectFiles = ("$module.pro") if (!@projectFiles && pretending());

    if (!@projectFiles || !$projectFiles[0]) {
        croak_internal("No *.pro files could be found for $module");
    }

    if (@projectFiles > 1) {
        error (" b[r[*] Too many possible *.pro files for $module");
        return 0;
    }

    p_chdir($builddir);

    my $qmake = absPathToQMake();
    return 0 unless $qmake;

    return log_command($module, 'qmake', [ $qmake, @qmakeOpts, $projectFiles[0] ]) == 0;
}

1;
