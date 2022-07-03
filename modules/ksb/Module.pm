package ksb::Module 0.20;

# Class: Module
#
# Represents a source code module of some sort, which can be updated, built,
# and installed. Includes a stringifying overload and can be sorted amongst
# other ksb::Modules.

use ksb;

use parent qw(ksb::OptionsBase);

use ksb::IPC;
use ksb::Debug;
use ksb::Util;

use ksb::Updater::Svn;
use ksb::Updater::Git;
use ksb::Updater::Bzr;
use ksb::Updater::KDEProject;
use ksb::Updater::KDEProjectMetadata;
use ksb::Updater::Qt5;

use ksb::BuildException 0.20;

use ksb::BuildSystem 0.30;
use ksb::BuildSystem::Autotools;
use ksb::BuildSystem::QMake;
use ksb::BuildSystem::Qt4;
use ksb::BuildSystem::Qt5;
use ksb::BuildSystem::Qt6;
use ksb::BuildSystem::KDECMake;
use ksb::BuildSystem::CMakeBootstrap;
use ksb::BuildSystem::Meson;

use ksb::ModuleSet::Null;

use Storable 'dclone';
use Carp 'confess';
use Scalar::Util 'blessed';
use overload
    '""' => 'toString', # Add stringify operator.
    '<=>' => 'compare',
    ;

sub new
{
    my ($class, $ctx, $name) = @_;

    croak_internal ("Empty ksb::Module constructed") unless $name;

    my $self = ksb::OptionsBase::new($class);

    # If building a BuildContext instead of a ksb::Module, then the context
    # can't have been setup yet...
    my $contextClass = 'ksb::BuildContext';
    if ($class ne $contextClass &&
        (!blessed($ctx) || !$ctx->isa($contextClass)))
    {
        croak_internal ("Invalid context $ctx");
    }

    # Clone the passed-in phases so we can be different.
    my $phases = dclone($ctx->phases()) if $ctx;

    my %newOptions = (
        name         => $name,
        scm_obj      => undef,
        build_obj    => undef,
        phases       => $phases,
        context      => $ctx,
        'module-set' => undef,
        post_build_msgs => [ ],
    );

    @{$self}{keys %newOptions} = values %newOptions;

    return $self;
}

sub phases
{
    my $self = shift;
    return $self->{phases};
}

sub moduleSet
{
    my ($self) = @_;
    $self->{'module-set'} //= ksb::ModuleSet::Null->new();
    return $self->{'module-set'};
}

sub setModuleSet
{
    my ($self, $moduleSet) = @_;
    assert_isa($moduleSet, 'ksb::ModuleSet');
    $self->{'module-set'} = $moduleSet;
}

# Subroutine to retrieve a subdirectory path with tilde-expansion and
# relative path handling.
# The parameter is the option key (e.g. build-dir or log-dir) to read and
# interpret.
sub getSubdirPath
{
    my ($self, $subdirOption) = @_;
    my $dir = $self->getOption($subdirOption);

    # If build-dir starts with a slash, it is an absolute path.
    return $dir if $dir =~ /^\//;

    # Make sure we got a valid option result.
    if (!$dir) {
        confess ("Reading option for $subdirOption gave empty \$dir!");
    }

    # If it starts with a tilde, expand it out.
    if ($dir =~ /^~/)
    {
        $dir =~ s/^~/$ENV{'HOME'}/;
    }
    else
    {
        # Relative directory, tack it on to the end of $kdesrcdir.
        my $kdesrcdir = $self->getOption('source-dir');
        $dir = "$kdesrcdir/$dir";
    }

    return $dir;
}

# Method: getInstallPathComponents
#
# Returns the directory that a module should be installed in.
#
# NOTE: The return value is a hash. The key 'module' will return the final
# module name, the key 'path' will return the full path to the module. The
# key 'fullpath' will return their concatenation.
#
# For example, with $module == 'KDE/kdelibs', and no change in the dest-dir
# option, you'd get something like:
#
# > {
# >   'path'     => '/home/user/kdesrc/KDE',
# >   'module'   => 'kdelibs',
# >   'fullpath' => '/home/user/kdesrc/KDE/kdelibs'
# > }
#
# If dest-dir were changed to e.g. extragear-multimedia, you'd get:
#
# > {
# >   'path'     => '/home/user/kdesrc',
# >   'module'   => 'extragear-multimedia',
# >   'fullpath' => '/home/user/kdesrc/extragear-multimedia'
# > }
#
# Parameters:
#   pathType - Either 'source' or 'build'.
#
# Returns:
#   hash (Not a hashref; See description).
sub getInstallPathComponents
{
    my $module = assert_isa(shift, 'ksb::Module');
    my $type = shift;
    my $destdir = $module->destDir();
    my $srcbase = $module->getSourceDir();
    $srcbase = $module->getSubdirPath('build-dir') if $type eq 'build';

    my $combined = "$srcbase/$destdir";

    # Remove dup //
    $combined =~ s/\/+/\//;

    my @parts = split(/\//, $combined);
    my %result = ();
    $result{'module'} = pop @parts;
    $result{'path'} = join('/', @parts);
    $result{'fullpath'} = "$result{path}/$result{module}";

    my $compatDestDir = $module->destDir($module->name());
    my $fullCompatPath = "$srcbase/$compatDestDir";

    # We used to have code here to migrate very old directory layouts. It was
    # removed as of about 2013-09-29.

    return %result;
}

# Do note that this returns the *base* path to the source directory,
# without the module name or kde_projects stuff appended. If you want that
# use subroutine fullpath().
sub getSourceDir
{
    my $self = shift;
    return $self->getSubdirPath('source-dir');
}

sub name
{
    my $self = shift;
    return $self->{name};
}

sub scm
{
    my $self = shift;

    return $self->{scm_obj} if $self->{scm_obj};

    # Look for specific setting of repository and svn-server. If both is
    # set it's a bug, if one is set, that's the type (because the user says
    # so...). Don't use getOption($key) as it will try to fallback to
    # global options.

    my $svn_status = $self->getOption('svn-server', 'module');
    my $repository = $self->getOption('repository', 'module') // '';
    my $rcfile = $self->buildContext()->rcFile();

    if ($svn_status && $repository) {
        error (<<EOF);
You have specified both y[b[svn-server] and y[b[repository] options for the
b[$self] module in $rcfile.

You should only specify one or the other -- a module cannot be both types
- svn-server uses Subversion.
- repository uses git.
EOF
        die (make_exception('Config', 'svn-server and repository both set'));
    }

    # Overload repository to allow bzr URLs?
    if ($repository =~ /^bzr:\/\//) {
        $self->{scm_obj} = ksb::Updater::Bzr->new($self);
    }

    # If it needs a repo it's git. Everything else is svn for now.
    $self->{scm_obj} //=
        $repository
            ? ksb::Updater::Git->new($self)
            : ksb::Updater::Svn->new($self);

    return $self->{scm_obj};
}

sub setScmType
{
    my ($self, $scmType) = @_;

    my $newType;

    given($scmType) {
        when('git')  { $newType = ksb::Updater::Git->new($self); }
        when('proj') { $newType = ksb::Updater::KDEProject->new($self); }
        when('metadata') { $newType = ksb::Updater::KDEProjectMetadata->new($self); }
        when('svn')  { $newType = ksb::Updater::Svn->new($self); }
        when('bzr')  { $newType = ksb::Updater::Bzr->new($self); }
        when('qt5')  { $newType = ksb::Updater::Qt5->new($self); }
        default      { $newType = undef; }
    }

    $self->{scm_obj} = $newType;
}

# Returns a string describing the scm platform of the given module.
# Return value: 'git' or 'svn' at this point, as appropriate.
sub scmType
{
    my $self = shift;
    return $self->scm()->name();
}

sub currentScmRevision
{
    my $self = shift;

    return $self->scm()->currentRevisionInternal();
}

# Returns a new build system object, given the appropriate name.
# This is a sub-optimal way to fix the problem of allowing users to override
# the detected build system (we could instead use introspection to figure out
# available build systems at runtime). However, KISS...
sub buildSystemFromName
{
    my ($self, $name) = @_;
    my %buildSystemClasses = (
        'generic'         => 'ksb::BuildSystem',
        'qmake'           => 'ksb::BuildSystem::QMake',
        'cmake-bootstrap' => 'ksb::BuildSystem::CMakeBootstrap',
        'kde'             => 'ksb::BuildSystem::KDECMake',
        'qt'              => 'ksb::BuildSystem::Qt4',
        'qt5'             => 'ksb::BuildSystem::Qt5',
        'qt6'             => 'ksb::BuildSystem::Qt6',
        'autotools'       => 'ksb::BuildSystem::Autotools',
        'meson'           => 'ksb::BuildSystem::Meson',
    );

    my $class = $buildSystemClasses{lc $name} // undef;
    croak_runtime("Invalid build system $name requested")
        unless $class;

    return $class->new($self);
}

sub buildSystem
{
    my $self = shift;

    if ($self->{build_obj} && $self->{build_obj}->name() ne 'generic') {
        return $self->{build_obj};
    }

    if (my $userBuildSystem = $self->getOption('override-build-system')) {
        $self->{build_obj} = $self->buildSystemFromName($userBuildSystem);
        return $self->{build_obj};
    }

    # If not set, let's guess.
    my $buildType;
    my $sourceDir = $self->fullpath('source');

    if (($self->getOption('repository') =~ /gitorious\.org\/qt\//) ||
        ($self->getOption('repository') =~ /^kde:qt$/) ||
        (-e "$sourceDir/bin/syncqt"))
    {
        $buildType = ksb::BuildSystem::Qt4->new($self);
    }

    # This test must come before the KDE buildsystem's as cmake's own
    # bootstrap system also has CMakeLists.txt
    if (!$buildType && (-e "$sourceDir/CMakeLists.txt") &&
        (-e "$sourceDir/bootstrap"))
    {
        $buildType = ksb::BuildSystem::CMakeBootstrap->new($self);
    }

    if (!$buildType && (-e "$sourceDir/CMakeLists.txt" ||
            $self->getOption('#xml-full-path')))
    {
        $buildType = ksb::BuildSystem::KDECMake->new($self);
    }

    # We have to assign to an array to force glob to return all results,
    # otherwise it acts like a non-reentrant generator whose output depends on
    # how many times it's been called...
    if (!$buildType && (my @files = glob ("$sourceDir/*.pro"))) {
        $buildType = ksb::BuildSystem::QMake->new($self);
    }

    # 'configure' is a popular fall-back option even for other build
    # systems so ensure we check last for autotools.
    if (!$buildType &&
        (-e "$sourceDir/configure" || -e "$sourceDir/autogen.sh"))
    {
        $buildType = ksb::BuildSystem::Autotools->new($self);
    }

    # Someday move this up, but for now ensure that Meson happens after
    # configure/autotools support is checked for.
    if (!$buildType && -e "$sourceDir/meson.build") {
        $buildType = ksb::BuildSystem::Meson->new($self);
    }

    # Don't just assume the build system is KDE-based...
    $buildType //= ksb::BuildSystem->new($self);

    $self->{build_obj} = $buildType;

    return $self->{build_obj};
}

# Sets the build system **object**, although you can find the build system
# type afterwards (see buildSystemType).
sub setBuildSystem
{
    my ($self, $obj) = @_;

    assert_isa($obj, 'ksb::BuildSystem');
    $self->{build_obj} = $obj;
}

# Current possible build system types:
# KDE (i.e. cmake), Qt, autotools (either
# configure or autogen.sh). A final possibility is 'pendingSource' which
# simply means that we don't know yet.
#
# If the build system type is not set ('pendingSource' counts as being
# set!) when this function is called then it will be autodetected if
# possible, but note that not all possible types will be detected this way.
# If in doubt use setBuildSystemType
sub buildSystemType
{
    my $self = shift;
    return $self->buildSystem()->name();
}

# Subroutine to build this module.
# Returns boolean false on failure, boolean true on success.
sub build
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $moduleName = $self->name();
    my %pathinfo = $self->getInstallPathComponents('build');
    my $builddir = $pathinfo{'fullpath'};
    my $buildSystem = $self->buildSystem();

    if ($buildSystem->name() eq 'generic'
        && !pretending()
        && !$self->hasOption('custom-build-command')
    ) {
        error ("\tr[b[$self] does not seem to have a build system to use.");
        return 0;
    }

    # Ensure we're in a known directory before we start; some options remove
    # the old build directory that a previous module might have been using.
    super_mkdir($pathinfo{'path'});
    p_chdir($pathinfo{'path'});

    return 0 if !$self->setupBuildSystem();
    return 1 if $self->getOption('build-system-only');

    my $buildResults = $buildSystem->buildInternal();
    return 0 if !$buildResults->{was_successful};
    $self->setPersistentOption('last-build-rev', $self->currentScmRevision());

    # TODO: This should be a simple phase to run.
    $self->buildSystem()->runTestsuite()
        if $self->getOption('run-tests');

    if (!$buildResults->{work_done}) {
        info ("\tNo changes from build, skipping install (--refresh-build this module to force install)");
        return 1;
    }
    elsif (!$self->getOption('install-after-build')) {
        info ("\tSkipping install due to install-after-build setting");
        return 1;
    }

    # TODO: Likewise this should be a phase to run.
    return $self->install();
}

# Subroutine to setup the build system in a directory.
# Returns boolean true on success, boolean false (0) on failure.
sub setupBuildSystem
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $moduleName = $self->name();

    my $buildSystem = $self->buildSystem();

    if ($buildSystem->name() eq 'generic'
        && $self->hasOption('custom-build-command')
    ) {
        info (" b[*] No build system detected for b[y[$self], assuming custom build command will handle");
        return 1;
    }

    if ($buildSystem->name() eq 'generic' && !pretending()) {
        croak_internal('Build system determination still pending when build attempted.');
    }

    my $refreshReason = $buildSystem->needsRefreshed();
    if ($refreshReason ne "")
    {
        # The build system needs created, either because it doesn't exist, or
        # because the user has asked that it be completely rebuilt.
        info ("\tPreparing build system for y[$self].");

        # Check to see if we're actually supposed to go through the
        # cleaning process.
        if (!$self->getOption('#cancel-clean') &&
            !$buildSystem->cleanBuildSystem())
        {
            warning ("\tUnable to clean r[$self]!");
            return 0;
        }
    }

    if (!$buildSystem->createBuildSystem()) {
        error ("\tError creating r[$self]'s build system!");
        return 0;
    }

    # Now we're in the checkout directory
    # So, switch to the build dir.
    # builddir is automatically set to the right value for qt
    p_chdir ($self->fullpath('build'));

    if (!$buildSystem->configureInternal()) {
        error ("\tUnable to configure r[$self] with " . $self->buildSystemType());

        # Add undocumented ".refresh-me" file to build directory to flag
        # for --refresh-build for this module on next run. See also the
        # "needsRefreshed" subroutine.
        if (open my $fh, '>', '.refresh-me') {
            say $fh "# Build directory will be re-generated next kdesrc-build run";
            say $fh "# due to failing to complete configuration on the last run";
            close $fh;
        };

        return 0;
    }

    return 1;
}

# Responsible for installing the module (no update, build, etc.)
# Return value: Boolean flag indicating whether module installed successfully or
# not.
# Exceptions may be thrown for abnormal conditions (e.g. no build dir exists)
sub install
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $builddir = $self->fullpath('build');
    my $buildSysFile = $self->buildSystem()->configuredModuleFileName();

    if (!pretending() && ! -e "$builddir/$buildSysFile")
    {
        warning ("\tThe build system doesn't exist for r[$self].");
        warning ("\tTherefore, we can't install it. y[:-(].");
        return 0;
    }

    $self->setupEnvironment();

    my @makeInstallOpts = split(' ', $self->getOption('make-install-prefix'));

    # We can optionally uninstall prior to installing
    # to weed out old unused files.
    if ($self->getOption('use-clean-install') &&
        $self->getPersistentOption('last-install-rev'))
    {
        if (!$self->buildSystem()->uninstallInternal(@makeInstallOpts)) {
            warning ("\tUnable to uninstall r[$self] before installing the new build.");
            warning ("\tContinuing anyways...");
        }
        else {
            $self->unsetPersistentOption('last-install-rev');
        }
    }

    if (!$self->buildSystem()->installInternal(@makeInstallOpts))
    {
        error ("\tUnable to install r[$self]!");
        $self->buildContext()->markModulePhaseFailed('install', $self);
        return 0;
    }

    if (pretending())
    {
        pretend ("\tWould have installed g[$self]");
        return 1;
    }

    # Past this point we know we've successfully installed, for real.

    $self->setPersistentOption('last-install-rev', $self->currentScmRevision());

    my $remove_setting = $self->getOption('remove-after-install');

    # Possibly remove the srcdir and builddir after install for users with
    # a little bit of HD space.
    if($remove_setting eq 'all')
    {
        # Remove srcdir
        my $srcdir = $self->fullpath('source');
        note ("\tRemoving b[r[$self source].");
        safe_rmtree($srcdir);
    }

    if($remove_setting eq 'builddir' || $remove_setting eq 'all')
    {
        # Remove builddir
        note ("\tRemoving b[r[$self build directory].");
        safe_rmtree($builddir);

        # We're likely already in the builddir, so chdir back to the root
        p_chdir('/');
    }

    return 1;
}

# Handles uninstalling this module (or its sub-directories as given by the checkout-only
# option).
#
# Returns boolean false on failure, boolean true otherwise.
sub uninstall
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $builddir = $self->fullpath('build');
    my $buildSysFile = $self->buildSystem()->configuredModuleFileName();

    if (!pretending() && ! -e "$builddir/$buildSysFile")
    {
        warning ("\tThe build system doesn't exist for r[$self].");
        warning ("\tTherefore, we can't uninstall it.");
        return 0;
    }

    $self->setupEnvironment();

    my @makeInstallOpts = split(' ', $self->getOption('make-install-prefix'));

    if (!$self->buildSystem()->uninstallInternal(@makeInstallOpts))
    {
        error ("\tUnable to uninstall r[$self]!");
        $self->buildContext()->markModulePhaseFailed('install', $self);
        return 0;
    }

    if (pretending())
    {
        pretend ("\tWould have uninstalled g[$self]");
        return 1;
    }

    $self->unsetPersistentOption('last-install-rev');
    return 1;
}

sub buildContext
{
    my $self = shift;
    return $self->{context};
}

# Integrates 'set-env' option to the build context environment
sub applyUserEnvironment
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $ctx = $self->buildContext();

    # Let's see if the user has set env vars to be set.
    # Note the global set-env must be checked separately anyways, so
    # we limit inheritance when searching.
    my $env_hash_ref = $self->getOption('set-env', 'module');

    while (my ($key, $value) = each %{$env_hash_ref})
    {
        $ctx->queueEnvironmentVariable($key, $value);
    }
}

# Establishes proper build environment in the build context. Should be run
# before forking off commands for e.g. updates, builds, installs, etc.
sub setupEnvironment
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $ctx = $self->buildContext();
    my $prefix = $self->installationPath();

    # Add global set-envs and context
    $self->buildContext()->applyUserEnvironment();

    # Build system's environment injection
    my $buildSystem = $self->buildSystem();

    #
    # Suppress injecting qtdir/kdedir related environment variables if a toolchain is also set
    # Let the toolchain files/definitions take care of themselves.
    #
    if ($buildSystem->hasToolchain()) {
        note ("\tNot setting environment variables for b[$self]: a custom toolchain is used");
    } else {
        my $kdedir = $self->getOption('kdedir');
        my $qtdir  = $self->getOption('qtdir');
        my $binpath  = $self->getOption('binpath');
        my $libpath  = $self->getOption('libpath');

        # Ensure the platform libraries we're building can be found, as long as they
        # are not the system's own libraries.
        for my $platformDir ($qtdir, $kdedir) {
            next unless $platformDir;       # OK, assume system platform is usable
            next if $platformDir eq '/usr'; # Don't 'fix' things if system platform
                                            # manually set

            $ctx->prependEnvironmentValue('PKG_CONFIG_PATH', "$platformDir/lib/pkgconfig");
            $ctx->prependEnvironmentValue('LD_LIBRARY_PATH', "$platformDir/lib");
            $ctx->prependEnvironmentValue('PATH', "$platformDir/bin");
        }
        if (length $binpath) {
            $ctx->prependEnvironmentValue('PATH', $binpath);
        }
        if (length $libpath) {
            $ctx->prependEnvironmentValue('LD_LIBRARY_PATH', $libpath);
        }
    }

    $buildSystem->prepareModuleBuildEnvironment($ctx, $self, $prefix);

    # Read in user environment defines
    $self->applyUserEnvironment() unless $self == $ctx;
}

# Returns the path to the log directory used during this run for this
# ksb::Module, based on an autogenerated unique id. The id doesn't change
# once generated within a single run of the script.
sub getLogDir
{
    my ($self) = @_;
    return $self->buildContext()->getLogDirFor($self);
}

# Returns a full path that can be open()'d to write a log
# file, based on the given basename (with extension).
# Updates the 'latest' symlink as well, unlike getLogDir
# Use when you know you're going to create a new log
sub getLogPath
{
    my ($self, $path) = @_;
    return $self->buildContext()->getLogPathFor($self, $path);
}

sub toString
{
    my $self = shift;
    return $self->name();
}

sub compare
{
    my ($self, $other) = @_;
    return $self->name() cmp $other->name();
}

sub update
{
    my ($self, $ipc, $ctx) = @_;

    my $moduleName = $self->name();
    my $module_src_dir = $self->getSourceDir();
    my $kdesrc = $ctx->getSourceDir();

    if ($kdesrc ne $module_src_dir)
    {
        # This module has a different source directory, ensure it exists.
        if (!super_mkdir($module_src_dir))
        {
            error ("Unable to create separate source directory for r[$self]: $module_src_dir");
            $ipc->sendIPCMessage(ksb::IPC::MODULE_FAILURE, $moduleName);
            next;
        }
    }

    my $fullpath = $self->fullpath('source');
    my $count;
    my $returnValue;

    eval { $count = $self->scm()->updateInternal($ipc) };

    if ($@)
    {
        my $reason = ksb::IPC::MODULE_FAILURE;

        if (had_an_exception()) {
            if ($@->{'exception_type'} eq 'ConflictPresent') {
                $reason = ksb::IPC::MODULE_CONFLICT;
            }
            else {
                $ctx->markModulePhaseFailed('build', $self);
            }

            $@ = $@->{'message'};
        }

        error ("Error updating r[$self], removing from list of packages to build.");
        error (" > y[$@]");

        $ipc->sendIPCMessage($reason, $moduleName);
        $self->phases()->filterOutPhase('build');
        $returnValue = 0;
    }
    else
    {
        my $message;
        if (not defined $count)
        {
            $message = ksb::Debug::colorize ("b[y[Unknown changes].");
            $ipc->notifyUpdateSuccess($moduleName, $message);
        }
        elsif ($count)
        {
            $message = "1 file affected." if $count == 1;
            $message = "$count files affected." if $count != 1;
            $ipc->notifyUpdateSuccess($moduleName, $message);
        }
        else
        {
            $message = "0 files affected.";
            my $refreshReason = $self->buildSystem()->needsRefreshed();

            $ipc->sendIPCMessage(ksb::IPC::MODULE_UPTODATE, "$moduleName,$refreshReason");
        }

        # We doing e.g. --src-only, the build phase that normally outputs
        # number of files updated doesn't get run, so manually mention it
        # here.
        if (!$ipc->supportsConcurrency()) {
            info ("\t$self update complete, $message");
        }

        $returnValue = 1;
    }

    info (""); # Print empty line.
    return $returnValue;
}

# OVERRIDE
#
# This calls OptionsBase::setOption and performs any Module-specific
# handling.
sub setOption
{
    my ($self, %options) = @_;

    # Ensure we don't accidentally get fed module-set options
    for (qw(git-repository-base use-modules ignore-modules)) {
        if (exists $options{$_}) {
            error (" r[b[*] module b[$self] should be declared as module-set to use b[$_]");
            die ksb::BuildException::Config->new($_, "Option $_ can only be used in module-set");
        };
    }

    # Special case handling.
    if (exists $options{'filter-out-phases'}) {
        for my $phase (split(' ', $options{'filter-out-phases'})) {
            $self->phases()->filterOutPhase($phase);
        }
        delete $options{'filter-out-phases'};
    }

    $self->SUPER::setOption(%options);
}

# OVERRIDE
#
# This subroutine returns an option value for a given module.  Some globals
# can't be overridden by a module's choice (but see 2nd parameter below).
# If so, the module's choice will be ignored, and a warning will be issued.
#
# Option names are case-sensitive!
#
# Some options (e.g. cmake-options, configure-flags) have the global value
# and then the module's own value appended together. To get the actual
# module setting you must use the level limit parameter set to 'module'.
#
# Likewise, some qt module options do not obey the previous proviso since
# Qt options are not likely to agree nicely with generic KDE buildsystem
# options.
#
# 1st parameter: Name of option
# 2nd parameter: Level limit (optional). If not present, then the value
# 'allow-inherit' is used. Options:
#   - allow-inherit: Module value is used if present (with exceptions),
#     otherwise global is used.
#   - module: Only module value is used (if you want only global then use the
#     buildContext) NOTE: This overrides global "sticky" options as well!
sub getOption
{
    my ($self, $key, $levelLimit) = @_;
    my $ctx = $self->buildContext();
    $levelLimit //= 'allow-inherit';

    # Some global options would probably make no sense applied to Qt.
    my @qtCopyOverrides = qw(branch configure-flags tag cxxflags);
    if (list_has(\@qtCopyOverrides, $key) && $self->buildSystemType() eq 'Qt') {
        $levelLimit = 'module';
    }

    assert_in($levelLimit, [qw(allow-inherit module)]);

    # If module-only, check that first.
    return $self->{options}{$key} if $levelLimit eq 'module';

    my $ctxValue = $ctx->getOption($key); # we'll use this a lot from here

    # Some global options always override module options.
    return $ctxValue if $ctx->hasStickyOption($key);

    # Some options append to the global (e.g. conf flags)
    my @confFlags = qw(cmake-options configure-flags cxxflags);
    if (list_has(\@confFlags, $key) && $ctxValue) {
        return trimmed("$ctxValue " . ($self->{options}{$key} || ''));
    }

    # Everything else overrides the global option, unless it's simply not
    # set at all.
    return $self->{options}{$key} // $ctxValue;
}

# Gets persistent options set for this module. First parameter is the name
# of the option to lookup. Undef is returned if the option is not set,
# although even if the option is set, the value returned might be empty.
# Note that ksb::BuildContext also has this function, with a slightly
# different signature, which OVERRIDEs this function since Perl does not
# have parameter-based method overloading.
sub getPersistentOption
{
    my ($self, $key) = @_;
    return $self->buildContext()->getPersistentOption($self->name(), $key);
}

# Sets a persistent option (i.e. survives between processes) for this module.
# First parameter is the name of the persistent option.
# Second parameter is its actual value.
# See the warning for getPersistentOption above, it also applies for this
# method vs. ksb::BuildContext::setPersistentOption
sub setPersistentOption
{
    my ($self, $key, $value) = @_;
    return $self->buildContext()->setPersistentOption($self->name(), $key, $value);
}

# Unsets a persistent option for this module.
# Only parameter is the name of the option to unset.
sub unsetPersistentOption
{
    my ($self, $key) = @_;
    $self->buildContext()->unsetPersistentOption($self->name(), $key);
}

# Returns the path to the desired directory type (source or build),
# including the module destination directory itself.
sub fullpath
{
    my ($self, $type) = @_;
    assert_in($type, [qw/build source/]);

    my %pathinfo = $self->getInstallPathComponents($type);
    return $pathinfo{'fullpath'};
}

# Returns the "full kde-projects path" for the module. As should be obvious by
# the description, this only works for modules with an scm type that is a
# Updater::KDEProject (or its subclasses), but modules that don't fall into this
# hierarchy will just return the module name (with no path components) anyways.
sub fullProjectPath
{
    my $self = shift;
    return ($self->getOption('#xml-full-path', 'module') || $self->name());
}

# Returns true if this module is (or was derived from) a kde-projects module.
sub isKDEProject
{
    my $self = shift;
    return $self->hasOption('#xml-full-path');
}

# Subroutine to return the name of the destination directory for the
# checkout and build routines.  Based on the dest-dir option.  The return
# value will be relative to the src/build dir.  The user may use the
# '$MODULE' or '${MODULE}' sequences, which will be replaced by the name of
# the module in question.
#
# The first parameter is optional, but if provided will be used as the base
# path to replace $MODULE entries in dest-dir.
sub destDir
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $destDir = $self->getOption('dest-dir');

    my $basePath = "";
    my $layout = $self->getOption('directory-layout');
    my $oldlayout = $self->getOption('ignore-kde-structure');
    if ($oldlayout) {
        # avoid spamming
        if (!$self->getOption('#warned-deprecated-ignore-kde-structure')) {
            if($oldlayout eq 'true' || $oldlayout == 1) {
                warning("The option b[ignore-kde-structure true] is deprecated. Please replace it with b[directory-layout flat] in your configuration file.");
            } else {
                warning("The option b[ignore-kde-structure false] is deprecated. Please replace it with b[directory-layout invent] in your configuration file.");
            }
        }
        # no or equivalent layout configured, assume the user wants to use flat layout
        if (!$layout || $layout eq 'flat') {
            $layout = 'flat';
        } else {
            # avoid spamming
            if (!$self->getOption('#warned-deprecated-ignore-kde-structure')) {
                warning("Deprecated b[ignore-kde-structure] will be ignored in favour of b[directory-layout] for b[$self]");
            }
        }
        # avoid spamming
        $self->setOption('#warned-deprecated-ignore-kde-structure', 1);
    }

    if ($layout eq 'flat') {
        $basePath = $self->name();
    } else {
        # invent layout only works for proper KDE projects, which have a kde:(.*).git pattern repository configured
        if ($layout eq 'invent' && $self->getOption('repository') =~ m/kde:(.*)\.git/) {
            $basePath = $1;
        } else {
            if ($layout && $layout ne 'invent' && $layout ne 'metadata' &&
                !$self->getOption('#warned-invalid-directory-layout')) { # avoid spamming
                warning("Invalid b[directory-layout] value: $layout. Will use b[metadata] instead for b[$self]");
                $self->setOption('#warned-invalid-directory-layout', 1);
            }
            $basePath = shift // $self->getOption('#xml-full-path');
            $basePath ||= $self->name(); # Default if not provided in repo-metadata
        }
    }

    $destDir =~ s/(\$\{MODULE})|(\$MODULE\b)/$basePath/g;

    return $destDir;
}

# Subroutine to return the installation path of a given module (the value
# that is passed to the CMAKE_INSTALL_PREFIX CMake option).
# It is based on the "prefix" and, if it is not set, the "kdedir" option.
# The user may use '$MODULE' or '${MODULE}' in the "prefix" option to have
# them replaced by the name of the module in question.
sub installationPath
{
    my $self = assert_isa(shift, 'ksb::Module');
    my $path = $self->getOption('prefix');

    if (!$path)
    {
        return $self->getOption('kdedir');
    }

    my $moduleName = $self->name();
    $path =~ s/(\$\{MODULE})|(\$MODULE\b)/$moduleName/g;

    return $path;
}

# Returns a list of any 'post-build' messages that have been set for the module
# to show after the build has ended. These may be messages such as warning of a
# local source conflict that may have scrolled past or similar things the user
# needs to know about.
#
# Each entry in the list will be a text message that should be shown (perhaps
# with additional formatting).
sub getPostBuildMessages
{
    my $self = assert_isa(shift, 'ksb::Module');
    return @{$self->{post_build_msgs}};
}

# Adds the given message to the list of post-build messages to show to the user
sub addPostBuildMessage
{
    my ($self, $new_msg) = @_;

    push @{$self->{post_build_msgs}}, $new_msg;
    return;
}

1;
