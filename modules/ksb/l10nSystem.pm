package ksb::l10nSystem;

# This class is an implementation of both the source and build interfaces needed to
# support building KDE l10n modules.

use strict;
use warnings;
use 5.014;

our $VERSION = '0.10';

use ksb::Debug;
use ksb::Util;
use ksb::Updater::Svn;
use ksb::BuildSystem;

our @ISA = ('ksb::Updater::Svn', 'ksb::BuildSystem');

sub new
{
    my ($class, $module) = @_;

    # Ensure associated module updates from the proper svn path.
    # TODO: Support different localization branches?

    $module->setOption('module-base-path', 'trunk/l10n-kde4');
    return bless { module => $module, needsRefreshed => 1 }, $class;
}

sub module
{
    my $self = shift;
    return $self->{module};
}

sub configuredModuleFileName
{
    # Not quite correct (we should be looking at each individual language
    # but it at least keeps the process going.
    return 'teamnames';
}

# Sets the directories that are to be checked out/built/etc.
# There should be one l10nSystem for the entire l10n build (i.e. add
# all required support dirs and languages).
sub setLanguageDirs
{
    my ($self, @languageDirs) = @_;
    $self->{l10n_dirs} = \@languageDirs;
}

# Returns true if the given subdirectory (reference from the module's root source directory)
# can be built or not. Should be reimplemented by subclasses as appropriate.
sub isSubdirBuildable
{
    my ($self, $subdir) = @_;
    return ($subdir ne 'scripts' && $subdir ne 'templates');
}

sub prefixEnvironmentVariable
{
    return 'CMAKE_PREFIX_PATH';
}

# scm-specific update procedure.
# May change the current directory as necessary.
sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater');
    my $module = $self->module();
    my $fullpath = $module->fullpath('source');
    my @dirs = @{$self->{l10n_dirs}};

    if (-e "$fullpath/.svn") {
        $self->check_module_validity();
        my $count = $self->update_module_path(@dirs);

        $self->{needsRefreshed} = 0 if $count == 0;
        return $count;
    }
    else {
        return $self->checkout_module_path(@dirs);
    }
}

sub name
{
    return 'l10n';
}

# Returns a list of just the languages to install.
sub languages
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');
    my @langs = @{$self->{l10n_dirs}};

    return grep { $self->isSubdirBuildable($_); } (@langs);
}

# Buildsystem support section

sub needsRefreshed
{
    my $self = shift;

    # Should be 1 except if no update happened.
    return $self->{needsRefreshed};
}

sub buildInternal
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');
    my $builddir = $self->module()->fullpath('build');
    my @langs = $self->languages();
    my $result = 0;

    $result = ($self->safe_make({
        target => undef,
        message => "Building localization for language...",
        logbase => "build",
        subdirs => \@langs,
    }) == 0) || $result;

    return $result;
}

sub configureInternal
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');

    my $builddir = $self->module()->fullpath('build');
    my @langs = $self->languages();
    my $result = 0;

    for my $lang (@langs) {
        my $prefix = $self->module()->installationPath();
        p_chdir("$builddir/$lang");

        info ("\tConfiguring to build language $lang");
        $result = (log_command($self->module(), "cmake-$lang",
            ['cmake', '-DCMAKE_INSTALL_PREFIX=' . $prefix]) == 0) || $result;
    }

    return $result;
}

sub installInternal
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');
    my $builddir = $self->module()->fullpath('build');
    my @langs = $self->languages();

    return ($self->safe_make({
        target => 'install',
        message => "Installing language...",
        logbase => "install",
        subdirs => \@langs,
    }) == 0);
}

# Subroutine to link a source directory into an alternate directory in
# order to fake srcdir != builddir for modules that don't natively support
# it.  The first parameter is the module to prepare.
#
# The return value is true (non-zero) if it succeeded, and 0 (false) if it
# failed.
#
# On return from the subroutine the current directory will be in the build
# directory, since that's the only directory you should touch from then on.
sub prepareFakeBuilddir
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');
    my $srcdir = $module->fullpath('source');

    # List reference, not a real list.  The initial kdesrc-build does *NOT*
    # fork another kdesrc-build using exec, see sub log_command() for more
    # info.
    my $args = [ 'kdesrc-build', 'main::safe_lndir', $srcdir, $builddir ];

    info ("\tSetting up alternate build directory for l10n");
    return (0 == log_command ($module, 'create-builddir', $args));
}

# Subroutine to create the build system for a module.  This involves making
# sure the directory exists and then running any preparatory steps (like
# for l10n modules).  This subroutine assumes that the module is already
# downloaded.
#
# Return convention: boolean (inherited)
sub createBuildSystem
{
    my $self = assert_isa(shift, 'ksb::l10nSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');

    # l10n doesn't support srcdir != builddir, fake it.
    whisper ("\tFaking builddir for g[$module]");
    if (!$self->prepareFakeBuilddir())
    {
        error ("Error creating r[$module] build system!");
        return 0;
    }

    p_chdir ($builddir);

    my @langs = @{$self->{l10n_dirs}};
    @langs = grep { $self->isSubdirBuildable($_) } (@langs);

    foreach my $lang (@langs) {
        my $cmd_ref = [ './scripts/autogen.sh', $lang ];
        if (log_command ($module, "build-system-$lang", $cmd_ref))
        {
            error ("\tUnable to create build system for r[$module]");
        }
    }

    $module->setOption('#reconfigure', 1); # Force reconfigure of the module

    return 1;
}

1;
