package ksb::BuildContext 0.30;

# Class: BuildContext
#
# This contains the information needed about the build context, e.g.  list of
# modules, what phases each module is in, the various options, etc.

use 5.014;
use warnings;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

use Carp 'confess';
use File::Basename; # dirname
use IO::File;
use POSIX qw(strftime);
use Errno qw(:POSIX);

# We derive from ksb::Module so that BuildContext acts like the 'global'
# ksb::Module, with some extra functionality.
# TODO: Derive from OptionsBase directly and remove getOption override
use parent qw(ksb::Module);

use ksb::Debug;
use ksb::Util;
use ksb::PhaseList;
use ksb::Module;
use ksb::Module::BranchGroupResolver;
use ksb::Updater::KDEProjectMetadata;
use ksb::Version qw(scriptVersion);
use ksb::StatusView;

use File::Temp qw(tempfile);
use File::Spec; # rel2abs

my @DefaultPhases = qw/update build install/;
my @rcfiles = ("./kdesrc-buildrc", "$ENV{HOME}/.kdesrc-buildrc");
my $LOCKFILE_NAME = '.kdesrc-lock';

# The # will be replaced by the directory the rc File is stored in.
my $PERSISTENT_FILE_NAME = '#/.kdesrc-build-data';

my $SCRIPT_VERSION = scriptVersion();

# Should be used for internal state that shouldn't be exposed as a hidden
# cmdline option, or has other cmdline switches (e.g. debug/verbose handling).
my %internalGlobalOptions = (
    "async"                => 1,
    "build-system-only"    => "",
    "build-when-unchanged" => 1, # Safe default
    "checkout-only"        => "",
    "colorful-output"      => 1, # Use color by default.
    "debug-level"          => ksb::Debug::INFO,
    "filter-out-phases"    => '',
    "git-desired-protocol" => 'git', # protocol to grab from kde-projects
    "git-repository-base"  => {}, # Base path template for use multiple times.
    "ignore-modules"       => '', # See also: use-modules, kde-projects
    "include-dependencies" => 0,  # Recursively include kde-projects module deps?
    "manual-build"         => "",
    "manual-update"        => "",
    "niceness"             => "10",
    "no-svn"               => "",  # TODO: Rename to no-src
    "prefix"               => "", # Override installation prefix.
    "pretend"              => "",
    "reconfigure"          => "",
    "refresh-build"        => "",
    "repository"           => '',     # module's git repo
    "revision"             => '', # Only useful for Subversion modules at cmdline
    "set-env"              => { }, # Hash of environment vars to set
    "ssh-identity-file"    => '', # If set, is passed to ssh-add.
    "use-modules"          => "",
);

# Holds boolean flags that could be altered from cmdline.
our %defaultGlobalFlags = (
    "delete-my-patches"    => 0, # Should only be set from cmdline
    "delete-my-settings"   => 0, # Should only be set from cmdline
    "disable-agent-check"  => 0, # If true we don't check on ssh-agent
    "ignore-kde-structure" => 0, # Whether to use kde dir structure like extragear/network
    "install-after-build"  => 1,  # Default to true
    "install-session-driver" => 0,# Default to false
    "purge-old-logs"       => 1,
    "run-tests"            => 0,  # 1 = make test, upload = make Experimental
    "stop-on-failure"      => 0,
    "use-clean-install"    => 0,
    "use-idle-io-priority" => 0,
    # Controls whether to build "stable" branches instead of "master"
    "use-stable-kde"       => 0,
);

# Holds other cmdline-accessible options that aren't simply binary flags.
our %defaultGlobalOptions = (
    "binpath"              => '',
    "branch"               => "",
    "branch-group"         => "", # Overrides branch, uses JSON data.
    "build-dir"            => "build",
    "cmake-options"        => "",
    "configure-flags"      => "",
    "custom-build-command" => '',
    "cxxflags"             => "-pipe",
    "dest-dir"             => '${MODULE}', # single quotes used on purpose!
    "do-not-compile"       => "",
    "http-proxy"           => '', # Proxy server to use for HTTP.
    "kdedir"               => "$ENV{HOME}/kde",
    "kde-languages"        => "",
    "libpath"              => "",
    "log-dir"              => "log",
    "make-install-prefix"  => "",  # Some people need sudo
    "make-options"         => "",
    "module-base-path"     => "",  # Used for tags and branches
    "override-build-system"=> "",
    "override-url"         => "",
    "persistent-data-file" => "",
    "qtdir"                => "$ENV{HOME}/qt4",
    "remove-after-install" => "none", # { none, builddir, all }
    "source-dir"           => "$ENV{HOME}/kdesrc",
    "svn-server"           => "svn://anonsvn.kde.org/home/kde",
    "tag"                  => "",
);

sub new
{
    my ($class, @args) = @_;

    # It is very important to use the ksb::Module:: syntax instead of ksb::Module->,
    # otherwise you can't pass $class and have it used as the classname.
    my $self = ksb::Module::new($class, undef, 'global');
    my %newOpts = (
        modules => [],
        context => $self, # Fix link to buildContext (i.e. $self)
        build_options => {
            global => {
                %internalGlobalOptions,
                %defaultGlobalFlags,
                %defaultGlobalOptions,
            },
            # Module options are stored under here as well, keyed by module->name()
        },
        # This one replaces ksb::Module::{phases}
        phases  => ksb::PhaseList->new(@DefaultPhases),
        errors  => {
            # A map from module *names* (as in modules[] above) to the
            # phase name at which they failed.
        },
        logPaths=> {
            # Holds a hash table of log path bases as expanded by
            # getSubdirPath (e.g. [source-dir]/log) to the actual log dir
            # *this run*, with the date and unique id added. You must still
            # add the module name to use.
        },
        rcFiles => [@rcfiles],
        rcFile  => undef,
        env     => { },
        ignore_list => [ ], # List of XML paths to ignore completely.
        kde_projects_filehandle => undef, # Filehandle to read database from.
        kde_projects_metadata   => undef, # See ksb::Module::KDEProjects
        logical_module_resolver => undef, # For branch-group option.
        status_view => ksb::StatusView->new(),
    );

    # Merge all new options into our self-hash.
    @{$self}{keys %newOpts} = values %newOpts;
    $self->{options} = $self->{build_options}{global};

    assert_isa($self, 'ksb::Module');
    assert_isa($self, 'ksb::BuildContext');

    return $self;
}

# Gets the ksb::PhaseList for this context, and optionally sets it first to
# the ksb::PhaseList passed in.
sub phases
{
    my ($self, $phases) = @_;

    if ($phases) {
        confess("Invalid type, expected PhaseList")
            unless $phases->isa('ksb::PhaseList');
        $self->{phases} = $phases;
    }
    return $self->{phases};
}

sub addModule
{
    my ($self, $module) = @_;
    Carp::confess("No module to push") unless $module;

    my $path;
    if (list_has($self->{modules}, $module)) {
        debug("Skipping duplicate module ", $module->name());
    }
    # TODO: Shouldn't this support all modules, not just 'proj' modules?
    elsif ($module->scmType() eq 'proj' &&
           ($path = $module->fullProjectPath()) &&
        # See if the name matches any given in the ignore list.
           any(sub { $path =~ /(^|\/)$_($|\/)/ }, $self->{ignore_list}))
    {
        debug("Skipping ignored module $module");
    }
    else {
        debug("Adding $module to module list");
        push @{$self->{modules}}, $module;
    }
}

# Returns a listref of the modules to build
sub moduleList
{
    my $self = shift;
    return $self->{modules};
}

# Adds a list of modules to ignore processing on completely.
# Parameters should simply be a list of XML repository paths to ignore,
# e.g. 'extragear/utils/kdesrc-build'. Partial paths are acceptable, matches
# are determined by comparing the path provided to the suffix of the full path
# of modules being compared.
#
# Existing items on the ignore list are not removed.
sub addToIgnoreList
{
    my $self = shift;
    push @{$self->{ignore_list}}, @_;

    debug ("Set context ignore list to ", join(', ', @_));
}

sub setupOperatingEnvironment
{
    my $self = shift;
    # Set the process priority
    POSIX::nice(int $self->getOption('niceness'));

    # Set the IO priority if available.
    if ($self->getOption('use-idle-io-priority')) {
        # -p $$ is our PID, -c3 is idle priority
        # 0 return value means success
        if (safe_system('ionice', '-c3', '-p', $$) != 0) {
            warning (" b[y[*] Unable to lower I/O priority, continuing...");
        }
    }

    # Get ready for logged output.
    ksb::Debug::setLogFile($self->getLogDirFor($self) . '/build-log');

    # Propagate HTTP proxy through environment unless overridden.
    if ((my $proxy = $self->getOption('http-proxy')) &&
        !defined $ENV{'http_proxy'})
    {
        $self->queueEnvironmentVariable('http_proxy', $proxy);
    }
}

# Clears the list of environment variables to set for log_command runs.
sub resetEnvironment
{
    my $self = assert_isa(shift, 'ksb::BuildContext');

    $self->{env} = { };
}

# Adds an environment variable and value to the list of environment
# variables to apply for the next subprocess execution.
#
# Note that these changes are /not/ reflected in the current environment,
# so if you are doing something that requires that kind of update you
# should do that yourself (but remember to have some way to restore the old
# value if necessary).
#
# In order to keep compatibility with the old 'setenv' sub, no action is
# taken if the value is not equivalent to boolean true.
sub queueEnvironmentVariable
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my ($key, $value) = @_;

    return unless $value;

    debug ("\tQueueing g[$key] to be set to y[$value]");
    $self->{env}->{$key} = $value;
}

# Applies all changes queued by queueEnvironmentVariable to the actual
# environment irretrievably. Use this before exec()'ing another child, for
# instance.
sub commitEnvironmentChanges
{
    my $self = assert_isa(shift, 'ksb::BuildContext');

    while (my ($key, $value) = each %{$self->{env}}) {
        $ENV{$key} = $value;
        debug ("\tSetting environment variable g[$key] to g[b[$value]");
    }
}

# Adds the given library paths to the path already given in an environment
# variable. In addition, detected "system paths" are stripped to ensure
# that we don't inadvertently re-add a system path to be promoted over the
# custom code we're compiling (for instance, when a system Qt is used and
# installed to /usr).
#
# If the environment variable to be modified has already been queued using
# queueEnvironmentVariable, then that (queued) value will be modified and
# will take effect with the next forked subprocess.
#
# Otherwise, the current environment variable value will be used, and then
# queued. Either way the current environment will be unmodified afterward.
#
# First parameter is the name of the environment variable to modify
# All remaining paramters are prepended to the current environment path, in
# the order given. (i.e. param1, param2, param3 ->
# param1:param2:param3:existing)
sub prependEnvironmentValue
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my ($envName, @items) = @_;
    my @curPaths = split(':', $self->{env}->{$envName} // $ENV{$envName} // '');

    # Filter out entries to add that are already in the environment from
    # the system.
    for my $path (grep { list_has(\@curPaths, $_) } (@items) ) {
        debug ("\tNot prepending y[$path] to y[$envName] as it appears " .
              "to already be defined in y[$envName].");
    }

    @items = grep { not list_has(\@curPaths, $_); } (@items);

    my $envValue = join(':', @items, @curPaths);

    $envValue =~ s/^:*//;
    $envValue =~ s/:*$//; # Remove leading/trailing colons
    $envValue =~ s/:+/:/; # Remove duplicate colons

    $self->queueEnvironmentVariable($envName, $envValue);
}

# Tries to take the lock for our current base directory, which currently is
# what passes for preventing people from accidentally running kdesrc-build
# multiple times at once.  The lock is based on the base directory instead
# of being global to allow for motivated and/or brave users to properly
# configure kdesrc-build to run simultaneously with different
# configurations.
#
# Return value is a boolean success flag.
sub takeLock
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my $baseDir = $self->baseConfigDirectory();
    my $lockfile = "$baseDir/$LOCKFILE_NAME";

    $! = 0; # Force reset to non-error status
    sysopen LOCKFILE, $lockfile, O_WRONLY | O_CREAT | O_EXCL;
    my $errorCode = $!; # Save for later testing.

    if ($errorCode == EEXIST)
    {
        # Path already exists, read the PID and see if it belongs to a
        # running process.
        open (my $pidFile, "<", $lockfile) or do
        {
            # Lockfile is there but we can't open it?!?  Maybe a race
            # condition but I have to give up somewhere.
            warning (" WARNING: Can't open or create lockfile r[$lockfile]");
            return 1;
        };

        my $pid = <$pidFile>;
        close $pidFile;

        if ($pid)
        {
            # Recent kdesrc-build; we wrote a PID in there.
            chomp $pid;

            # See if something's running with this PID.
            if (kill(0, $pid) == 1)
            {
                # Something *is* running, likely kdesrc-build.  Don't use error,
                # it'll scan for $!
                print ksb::Debug::colorize(" r[*y[*r[*] kdesrc-build appears to be running.  Do you want to:\n");
                print ksb::Debug::colorize("  (b[Q])uit, (b[P])roceed anyways?: ");

                my $choice = <STDIN> // '';
                chomp $choice;

                if (lc $choice ne 'p')
                {
                    say ksb::Debug::colorize(" y[*] kdesrc-build run canceled.");
                    return 0;
                }

                # We still can't grab the lockfile, let's just hope things
                # work out.
                note (" y[*] kdesrc-build run in progress by user request.");
                return 1;
            }

            # If we get here, then the program isn't running (or at least not
            # as the current user), so allow the flow of execution to fall
            # through below and unlink the lockfile.
        } # pid

        # No pid found, optimistically assume the user isn't running
        # twice.
        warning (" y[WARNING]: stale kdesrc-build lockfile found, deleting.");
        unlink $lockfile;

        sysopen (LOCKFILE, $lockfile, O_WRONLY | O_CREAT | O_EXCL) or do {
            error (" r[*] Still unable to lock $lockfile, proceeding anyways...");
            return 1;
        };

        # Hope the sysopen worked... fall-through
    }
    elsif ($errorCode == ENOTTY)
    {
        # Stupid bugs... normally sysopen will return ENOTTY, not sure who's to blame between
        # glibc and Perl but I know that setting PERLIO=:stdio in the environment "fixes" things.
        ; # pass
    }
    elsif ($errorCode != 0) # Some other error occurred.
    {
        warning (" r[*]: Error $errorCode while creating lock file (is $baseDir available?)");
        warning (" r[*]: Continuing the script for now...");

        # Even if we fail it's generally better to allow the script to proceed
        # without being a jerk about things, especially as more non-CLI-skilled
        # users start using kdesrc-build to build KDE.
        return 1;
    }

    say LOCKFILE "$$";
    close LOCKFILE;

    return 1;
}

# Releases the lock obtained by takeLock.
sub closeLock
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my $baseDir = $self->baseConfigDirectory();
    my $lockFile = "$baseDir/$LOCKFILE_NAME";

    unlink ($lockFile) or warning(" y[*] Failed to close lock: $!");
}

# This subroutine accepts a Module parameter, and returns the log directory
# for it. You can also pass a BuildContext (including this one) to get the
# default log directory.
#
# As part of setting up what path to use for the log directory, the
# 'latest' symlink will also be setup to point to the returned log
# directory.
sub getLogDirFor
{
    my ($self, $module) = @_;

    my $baseLogPath = $module->getSubdirPath('log-dir');
    my $logDir;

    if (!exists $self->{logPaths}{$baseLogPath}) {
        # No log dir made for this base, do so now.
        my $id = '01';
        my $date = strftime "%F", localtime; # ISO 8601 date
        $id++ while -e "$baseLogPath/$date-$id";
        $self->{logPaths}{$baseLogPath} = "$baseLogPath/$date-$id";
    }

    $logDir = $self->{logPaths}{$baseLogPath};
    return $logDir if pretending();

    super_mkdir($logDir) unless -e $logDir;

    # No symlink munging or module-name-adding is needed for the default
    # log dir.
    return $logDir if $module->isa('ksb::BuildContext');

    # Add a symlink to the latest run for this module.  'latest' itself is
    # a directory under the default log directory that holds module
    # symlinks, pointing to the last log directory run for that module.  We
    # do need to be careful of modules that have multiple directory names
    # though (like extragear/foo).

    my $latestPath = "$baseLogPath/latest";

    # Handle stuff like playground/utils or KDE/kdelibs
    my ($moduleName, $modulePath) = fileparse($module->name());
    $latestPath .= "/$modulePath" if $module->name() =~ m(/);

    super_mkdir($latestPath);

    my $symlinkTarget = "$logDir/$moduleName";
    my $symlink = "$latestPath/$moduleName";

    if (-l $symlink and readlink($symlink) ne $symlinkTarget)
    {
        unlink($symlink);
        symlink($symlinkTarget, $symlink);
    }
    elsif(not -e $symlink)
    {
        # Create symlink initially if we've never done it before.
        symlink($symlinkTarget, $symlink);
    }

    super_mkdir($symlinkTarget);
    return $symlinkTarget;
}

# Returns rc file in use. Call loadRcFile first.
sub rcFile
{
    my $self = shift;
    return $self->{rcFile};
}

# Forces the rc file to be read from to be that given by the first
# parameter.
sub setRcFile
{
    my ($self, $file) = @_;
    $self->{rcFiles} = [$file];
    $self->{rcFile} = undef;
}

# Returns an open filehandle to the user's chosen rc file.  Use setRcFile
# to choose a file to load before calling this function, otherwise
# loadRcFile will search the default search path.  After this function is
# called, rcFile() can be used to determine which file was loaded.
#
# If unable to find or open the rc file an exception is raised. Empty rc
# files are supported however.
sub loadRcFile
{
    my $self = shift;
    my @rcFiles = @{$self->{rcFiles}};
    my $fh;

    for my $file (@rcFiles)
    {
        if (open ($fh, '<', "$file"))
        {
            $self->{rcFile} = File::Spec->rel2abs($file);
            return $fh;
        }
    }

    # No rc found, check if we can use default.
    if (scalar @rcFiles == 1)
    {
        # This can only happen if the user uses --rc-file, so if we fail to
        # load the file, we need to fail to load at all.
        my $failedFile = $rcFiles[0];

        error (<<EOM);
Unable to open config file $failedFile

Script stopping here since you specified --rc-file on the command line to
load $failedFile manually.  If you wish to run the script with no configuration
file, leave the --rc-file option out of the command line.

If you want to force an empty rc file, use --rc-file /dev/null

EOM
        croak_runtime("Missing $failedFile");
    }

    # If no configuration but no --rc-file option was used, warn the user
    # and fail, as there are too many possible modes of using kdesrc-build
    # for kdesrc-buildrc-sample to be appropriate.

    error (<<EOM);
b[No configuration file is present.]

kdesrc-build requires a configuration file to select which KDE software modules
to build, what options to build them with, the path to install to, etc.

kdesrc-build looks for its configuration in the file `kdesrc-buildrc' in
whatever directory kdesrc-build is run from.

If no such file exists, kdesrc-build tries to use `~/.kdesrc-buildrc' (note the
leading `.')

A sample configuration suitable for KDE 4 software is included at the file
`kdesrc-buildrc-sample' which can be copied to the correct location and then
edited.

KDE Frameworks 5 users can use the `kdesrc-buildrc-kf5-sample' file which can
be copied to the correct location and then edited.

In either case b[once the configuration file is setup to your liking], you
should run:
b[kdesrc-build --metadata-only]

to download needed information about the KDE source repositories and then:
b[kdesrc-build --pretend]

to preview what kdesrc-build will do.
EOM
    croak_runtime("No configuration available");
}

# Returns the base directory that holds the configuration file. This is
# typically used as the directory base for other necessary kdesrc-build
# execution files, such as the persistent data store and lock file.
#
# The RC file must have been found and loaded first, obviously.
sub baseConfigDirectory
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my $rcfile = $self->rcFile() or
        croak_internal("Call to baseConfigDirectory before loadRcFile");

    return dirname($rcfile);
}

sub modulesInPhase
{
    my ($self, $phase) = @_;
    my @list = grep { list_has([$_->phases()->phases()], $phase) } (@{$self->moduleList()});
    return @list;
}

# Searches for a module with a name that matches the provided parameter,
# and returns its ksb::Module object. Returns undef if no match was found.
# As a special-case, returns the BuildContext itself if the name passed is
# 'global', since the BuildContext also is a (in the "is-a" OOP sense)
# ksb::Module, specifically the 'global' one.
sub lookupModule
{
    my ($self, $moduleName) = @_;

    return $self if $moduleName eq 'global';

    my @options = grep { $_->name() eq $moduleName } (@{$self->moduleList()});
    return undef unless @options;

    if (scalar @options > 1) {
        croak_internal("Detected 2 or more $moduleName ksb::Module objects");
    }

    return $options[0];
}

sub markModulePhaseFailed
{
    my ($self, $phase, $module) = @_;
    assert_isa($module, 'ksb::Module');

    $self->{errors}->{$module->name()} = $phase;
}

# Returns a list (i.e. not a reference to, but a real list) of Modules that failed to
# complete the given phase.
sub failedModulesInPhase
{
    my ($self, $phase) = @_;

    my @failures = grep {
        ($self->{errors}->{$_->name()} // '') eq $phase
    } (@{$self->moduleList()});

    return @failures;
}

# Returns a list of modules that had a failure of some sort, in the order the modules
# are listed in our current module list.
sub listFailedModules
{
    my $self = shift;
    my @modules = @{$self->moduleList()};

    # grepping for failures instead of returning error list directly maintains ordering
    @modules = grep {
        exists $self->{errors}->{$_->name()}
    } (@modules);

    return @modules;
}

# OVERRIDE: Our immediate parent class Module overrides this, but we actually
# want the OptionsBase version to be used instead, until we break the recursive
# use of Module's own getOption calls on our getOption.
sub getOption
{
    &ksb::OptionsBase::getOption;
}

# OVERRIDE: Overrides OptionsBase::setOption to handle some global-only options.
sub setOption
{
    my ($self, %options) = @_;

    # Actually set options.
    $self->SUPER::setOption(%options);

    # Automatically respond to various global option changes.
    while (my ($key, $value) = each %options) {
        my $normalizedKey = $key;
        $normalizedKey =~ s/^#//; # Remove sticky key modifier.
        given ($normalizedKey) {
            when ('colorful-output') { ksb::Debug::setColorfulOutput($value); }
            when ('debug-level')     { ksb::Debug::setDebugLevel($value); }
            when ('pretend')         { ksb::Debug::setPretending($value); }
        }
    }
}

#
# Persistent option handling
#

# Returns the name of the file to use for persistent data.
# Supports expanding '#' at the beginning of the filename to the directory
# containing the rc-file in use, but only for the default name at this
# point.
sub persistentOptionFileName
{
    my $self = shift;
    my $filename = $self->getOption('persistent-data-file');

    if (!$filename) {
        $filename = $PERSISTENT_FILE_NAME;
        my $dir = $self->baseConfigDirectory();
        $filename =~ s/^#/$dir/;
    }
    else {
        # Tilde-expand
        $filename =~ s/^~\//$ENV{HOME}\//;
    }

    return $filename;
}

# Reads in all persistent options from the file where they are kept
# (.kdesrc-build-data) for use in the program.
#
# The directory used is the same directory that contains the rc file in use.
sub loadPersistentOptions
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    my $fh = IO::File->new($self->persistentOptionFileName(), '<');

    return unless $fh;

    my $persistent_data;
    {
        local $/ = undef; # Read in whole file with <> operator.
        $persistent_data = <$fh>;
    }

    # $persistent_data should be Perl code which, when evaluated will give us
    # a hash called persistent_options which we can then merge into our
    # persistent options.

    my $persistent_options;

    # eval must appear after declaration of $persistent_options
    eval $persistent_data;
    if ($@)
    {
        # Failed.
        error ("Failed to read persistent module data: r[b[$@]");
        return;
    }

    # We need to keep persistent data with the context instead of with the
    # applicable modules since otherwise we might forget to write out
    # persistent data for modules we didn't build in this run. So, we just
    # store it all.
    # Layout of this data:
    #  $self->persistent_options = {
    #    'module-name' => {
    #      option => value,
    #      # foreach option/value pair
    #    },
    #    # foreach module
    #  }
    $persistent_options = {} if ref $persistent_options ne 'HASH';
    $self->{persistent_options} = $persistent_options;
}

# Writes out the persistent options to the file .kdesrc-build-data.
#
# The directory used is the same directory that contains the rc file in use.
sub storePersistentOptions
{
    my $self = assert_isa(shift, 'ksb::BuildContext');
    return if pretending();

    my $fh = IO::File->new($self->persistentOptionFileName(), '>');

    if (!$fh)
    {
        error ("Unable to save persistent module data: b[r[$!]");
        return;
    }

    print $fh "# AUTOGENERATED BY kdesrc-build $SCRIPT_VERSION\n";

    $Data::Dumper::Indent = 1;
    print $fh Data::Dumper->Dump([$self->{persistent_options}], ["persistent_options"]);
    undef $fh; # Closes the file
}

# Returns the value of a "persistent" option (normally read in as part of
# startup), or undef if there is no value stored.
#
# First parameter is the module name to get the option for, or 'global' if
# not for a module.
#     Note that unlike setOption/getOption, no inheritance is done at this
#     point so if an option is present globally but not for a module you
#     must check both if that's what you want.
# Second parameter is the name of the value to retrieve (i.e. the key)
sub getPersistentOption
{
    my ($self, $moduleName, $key) = @_;
    my $persistent_opts = $self->{persistent_options};

    # We must check at each level of indirection to avoid
    # "autovivification"
    return unless exists $persistent_opts->{$moduleName};
    return unless exists $persistent_opts->{$moduleName}{$key};

    return $persistent_opts->{$moduleName}{$key};
}

# Clears a persistent option if set (for a given module and option-name).
#
# First parameter is the module name to get the option for, or 'global' for
# the global options.
# Second parameter is the name of the value to clear.
# No return value.
sub unsetPersistentOption
{
    my ($self, $moduleName, $key) = @_;
    my $persistent_opts = $self->{persistent_options};

    if (exists $persistent_opts->{$moduleName} &&
        exists $persistent_opts->{$moduleName}->{$key})
    {
        delete $persistent_opts->{$moduleName}->{$key};
    }
}

# Sets a "persistent" option which will be read in for a module when
# kdesrc-build starts up and written back out at (normal) program exit.
#
# First parameter is the module name to set the option for, or 'global'.
# Second parameter is the name of the value to set (i.e. key)
# Third parameter is the value to store, which must be a scalar.
sub setPersistentOption
{
    my ($self, $moduleName, $key, $value) = @_;
    my $persistent_opts = $self->{persistent_options};

    # Initialize empty hash ref if nothing defined for this module.
    $persistent_opts->{$moduleName} //= { };

    $persistent_opts->{$moduleName}{$key} = $value;
}

# Tries to download the kde_projects.xml file needed to make XML module support
# work. Only tries once per script run. If it does succeed, the result is saved
# to $srcdir/kde_projects.xml
#
# Returns the file handle that the database can be retrieved from. May throw an
# exception if an error occurred.
sub getKDEProjectMetadataFilehandle
{
    my $self = assert_isa(shift, 'ksb::BuildContext');

    # Return our current filehandle if one exists.
    if (defined $self->{kde_projects_filehandle}) {
        my $fh = $self->{kde_projects_filehandle};
        $fh->seek(0, 0); # Return to start
        return $fh;
    }

    # Not previously attempted, let's make a try.
    my $srcdir = $self->getSourceDir();
    my $fileHandleResult = IO::File->new();

    super_mkdir($srcdir) unless -d "$srcdir";
    my $file = "$srcdir/kde_projects.xml";
    my $url = "http://projects.kde.org/kde_projects.xml";

    my $result = 1;

    # Must use ->phases() directly to tell if we will be updating since
    # modules are not all processed until after this function is called...
    my $updating = grep { /^update$/ } (@{$self->phases()});
    $updating &&= !$self->getOption('no-metadata');

    if ($updating && (! -e $file || !pretending())) {
        info (" * Downloading projects.kde.org project database...");
        $result = download_file($url, $file, $self->getOption('http-proxy'));
    }
    else {
        info (" * y[Using existing projects.kde.org project database], output may change");
        info (" * when database is updated next.");
    }

    if (!$result) {
        unlink $file if -e $file;
        croak_runtime("Unable to download kde_projects.xml for the kde-projects repository!");
    }

    if (!$fileHandleResult->opened()) {
        open ($fileHandleResult, '<', $file) or die
            make_exception('Runtime', "Unable to open $file: $!");
    }

    $self->{kde_projects_filehandle} = $fileHandleResult;
    return $fileHandleResult;
}

# Returns the ksb::Module (which has a 'metadata' scm type) that is used for
# kde-project metadata, so that other modules that need it can call into it if
# necessary.
#
# Also may return undef, if such metadata are unneeded, unavailable, or have
# not yet been set by setKDEProjectMetadataModule (this method does not
# automatically create the needed module).
sub getKDEProjectMetadataModule
{
    my $self = shift;
    return $self->{kde_projects_metadata};
}

# Call this method to force this build context to pull in the kde-projects
# metadata module. This is a one-time action, subsequent calls to this method
# are ignored. Use getKDEProjectMetadataModule to see if this build context is
# using a metadata module.
#
# This method should be called before setModuleList.
sub setKDEProjectMetadataModuleNeeded
{
    my $self = assert_isa(shift, 'ksb::BuildContext');

    return if defined $self->{kde_projects_metadata};

    my $metadata = ksb::ModuleSet::KDEProjects::getMetadataModule($self);

    debug ("Introducing metadata module into the build");
    assert_isa($metadata->scm(), 'ksb::Updater::KDEProjectMetadata');

    $self->{kde_projects_metadata} = $metadata;
    return;
}

# Returns the effective branch group to use for modules. You should not call
# this unless kde-build-metadata is also in use (see
# setKDEProjectMetadataModule and moduleBranchGroupResolver).
sub effectiveBranchGroup
{
    my $self = shift;
    my $branchGroup = $self->getOption('branch-group', 'module') // '';

    if (!$branchGroup) {
        $branchGroup = $self->getOption('use-stable-kde')
            ? 'latest-qt4'
            : ($self->hasOption('use-stable-kde') # Could also be false if unset
                ? 'kf5-qt5'      # Really set to false
                : 'latest-qt4'); # Unset / this is default branch group if no option set
    }

    return $branchGroup;
}

# Returns a ksb::Module::BranchGroupResolver which can be used to efficiently
# determine a git branch to use for a given kde-projects module (when the
# branch-group option is in use), as specified at
# http://community.kde.org/Infrastructure/Project_Metadata.
sub moduleBranchGroupResolver
{
    my $self = shift;

    if (!$self->{logical_module_resolver}) {
        my $metadataModule = $self->getKDEProjectMetadataModule();

        croak_internal("Tried to use branch-group, but needed data wasn't loaded!")
            unless $metadataModule;

        my $resolver = ksb::Module::BranchGroupResolver->new(
            $metadataModule->scm()->logicalModuleGroups());
        $self->{logical_module_resolver} = $resolver;
    }

    return $self->{logical_module_resolver};
}

sub statusViewer
{
    my $self = shift;
    return $self->{status_view};
}

1;
