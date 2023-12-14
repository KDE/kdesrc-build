package ksb::Application 0.20;

use ksb;

=head1 SYNOPSIS

 my $app = ksb::Application->new(@ARGV);

 my $result = $app->runAllModulePhases();

 $app->finish($result);

=head1 DESCRIPTION

Contains the application-layer logic (e.g. creating a build context, reading
options, parsing command-line, etc.).  Most of the specific tasks are delegated
to supporting classes, this class primarily does the orchestration that goes
from reading command line options, choosing which modules to build, overseeing
the build process, and reporting the results to the user.

=cut

# Class: Application
#

use ksb::BuildContext 0.35;
use ksb::BuildException 0.20;
use ksb::BuildSystem::QMake;
use ksb::Cmdline;
use ksb::DBus;
use ksb::Debug;
use ksb::DebugOrderHints;
use ksb::DependencyResolver 0.20;
use ksb::FirstRun;
use ksb::Module;
use ksb::ModuleResolver 0.20;
use ksb::ModuleSet 0.20;
use ksb::ModuleSet::KDEProjects;
use ksb::ModuleSet::Qt;
use ksb::RecursiveFH;
use ksb::TaskManager;
use ksb::Updater::Git;
use ksb::Util;

use Mojo::IOLoop;
use Mojo::Util ();

use Scalar::Util qw(blessed);
use List::Util qw(first min);
use File::Basename; # basename, dirname
use File::Copy ();  # copy
use File::Glob ':glob';
use POSIX qw(:sys_wait_h _exit :errno_h);

### Package-specific variables (not shared outside this file).

use constant {
    # We use a named remote to make some git commands work that don't accept the
    # full path.
    KDE_PROJECT_ID   => 'kde-projects',  # git-repository-base for sysadmin/repo-metadata
    QT_PROJECT_ID    => 'qt-projects',   # git-repository-base for qt.io Git repo
};

### Package methods

sub new
{
    my ($class, @options) = @_;

    my $self = bless {
        context         => ksb::BuildContext->new(),
        metadata_module => undef,
        run_mode        => 'build',
        modules         => undef,
        module_factory  => undef, # ref to sub that makes a new Module.
                                  # See generateModuleList
        _base_pid       => $$, # See finish()
    }, $class;

    # Default to colorized output if sending to TTY
    ksb::Debug::setColorfulOutput(-t STDOUT);

    my $workLoad = $self->generateModuleList(@options);
    if (!$workLoad->{build}) {
        print "No modules to build, exiting.\n";
        exit 0;
    }

    $self->{modules} = $workLoad->{selectedModules};
    $self->{workLoad} = $workLoad;

    $self->context()->setupOperatingEnvironment(); # i.e. niceness, ulimits, etc.

    # After this call, we must run the finish() method
    # to cleanly complete process execution.
    if (!pretending() && !$self->context()->takeLock())
    {
        print "$0 is already running!\n";
        exit 1; # Don't finish(), it's not our lockfile!!
    }

    # Install signal handlers to ensure that the lockfile gets closed.
    _installSignalHandlers(sub {
        note ("Signal received, terminating.");
        @main::atexit_subs = (); # Remove their finish, doin' it manually
        $self->finish(5);
    });

    return $self;
}

sub _findMissingModules
{
    # should be either strings of module names to be found or a listref containing
    # a list of modules where any one of which will work.
    my @requiredModules = (
        'HTTP::Tiny',
        'IO::Socket::SSL',
        [qw(JSON::XS JSON::PP)],
        [qw(YAML::XS YAML::PP YAML::Syck)]
    );
    my @missingModules;
    my $validateMod = sub {
        return eval "require $_[0]; 1;";
    };

    my $description;
    foreach my $neededModule (@requiredModules) {
        if (ref $neededModule) { # listref of options
            my @moduleOptions = @$neededModule;
            next if (ksb::Util::any (sub { $validateMod->($_); }, $neededModule));
            $description = 'one of (' . join(', ', @moduleOptions) . ')';
        }
        else {
            next if $validateMod->($neededModule);
            $description = $neededModule;
        }

        push @missingModules, $description;
    }

    return @missingModules;
}

sub _yieldModuleDependencyTreeEntry
{
    my ($nodeInfo, $module, $context) = @_;

    my $depth = $nodeInfo->{depth};
    my $index = $nodeInfo->{idx};
    my $count = $nodeInfo->{count};
    my $build = $nodeInfo->{build};
    my $currentItem = $nodeInfo->{currentItem};
    my $currentBranch = $nodeInfo->{currentBranch};
    my $parentItem = $nodeInfo->{parentItem};
    my $parentBranch = $nodeInfo->{parentBranch};

    my $buildStatus = $build ? 'built' : 'not built';
    my $statusInfo = $currentBranch ? "($buildStatus: $currentBranch)" : "($buildStatus)";

    my $connectorStack = $context->{stack};


    my $prefix = pop(@$connectorStack);

    while($context->{depth} > $depth) {
        $prefix = pop(@$connectorStack);
        --($context->{depth});
    }

    push(@$connectorStack, $prefix);

    my $connector;

    if ($depth == 0) {
        $connector = $prefix . ' ── ';
        push(@$connectorStack, $prefix . (' ' x 4));
    }
    else {
        $connector = $prefix . ($index == $count ? '└── ': '├── ');
        push(@$connectorStack, $prefix . ($index == $count ? ' ' x 4: '│   '));
    }

    $context->{depth} = $depth + 1;
    $context->{report}($connector . $currentItem . ' ' . $statusInfo);
}

# Generates the build context and module list based on the command line options
# and module selectors provided, resolves dependencies on those modules if needed,
# filters out ignored or skipped modules, and sets up the module factory.
#
# After this function is called all module set selectors will have been
# expanded, and we will have downloaded kde-projects metadata.
#
# Returns: a hash containing the following entries:
#
#  - selectedModules: the selected modules to build
#  - dependencyInfo: reference to dependency info object as created by ksb::DependencyResolver
#  - build: whether or not to actually perform a build action
#
sub generateModuleList
{
    my $self = shift;
    my @argv = @_;

    # Note: Don't change the order around unless you're sure of what you're
    # doing.

    my $ctx = $self->context();
    my $deferredOptions = [ ]; # 'options' blocks

    # Process --help, etc. first.
    my $opts = ksb::Cmdline::readCommandLineOptionsAndSelectors(@argv);
    my @selectors = @{$opts->{selectors}};
    my $cmdlineOptions = $opts->{opts};
    my $cmdlineGlobalOptions = $cmdlineOptions->{global};
    $ctx->phases->phases(@{$opts->{phases}});
    $self->{run_mode} = $opts->{run_mode};

    # Ensure some critical Perl modules are available so that the user isn't surprised
    # later with a Perl exception
    if(my @missingModuleDescriptions = _findMissingModules()) {
        say <<EOF;
kdesrc-build requires some minimal support to operate, including support
from the Perl runtime that kdesrc-build is built upon.

Some mandatory Perl modules are missing, and kdesrc-build cannot operate
without them.  Please ensure these modules are installed and available to Perl:
EOF
        say "\t$_" foreach @missingModuleDescriptions;

        say "\nkdesrc-build can do this for you on many distros:";
        say "Run 'kdesrc-build --initial-setup'";

        # TODO: Built-in mapping to popular distro package names??
        exit 1;
    }

    # Convert list to hash for lookup
    my %ignoredSelectors =
        map { $_, 1 } @{$opts->{'ignore-modules'}};

    my @startProgramAndArgs = @{$opts->{'start-program'}};

    # rc-file needs special handling.
    my $rcFile = $cmdlineGlobalOptions->{'rc-file'} // '';
    $rcFile =~ s/^~/$ENV{HOME}/;
    $ctx->setRcFile($rcFile) if ($rcFile);

    # disable async if only running a single phase.
#   $cmdlineGlobalOptions->{async} = 0 if (scalar $ctx->phases()->phases() == 1);

    my $fh = $ctx->loadRcFile();
    $ctx->loadPersistentOptions();

    if (exists $cmdlineGlobalOptions->{'resume'}) {
        my $moduleList = $ctx->getPersistentOption('global', 'resume-list');
        if (!$moduleList) {
            error ("b[--resume] specified, but unable to find resume point!");
            error ("Perhaps try b[--resume-from] or b[--resume-after]?");
            croak_runtime("Invalid --resume flag");
        }

        unshift @selectors, split(/,\s*/, $moduleList);
    }

    if (exists $cmdlineGlobalOptions->{'rebuild-failures'}) {
        my $moduleList = $ctx->getPersistentOption('global', 'last-failed-module-list');
        if (!$moduleList) {
            error ("b[y[--rebuild-failures] was specified, but unable to determine");
            error ("which modules have previously failed to build.");
            croak_runtime("Invalid --rebuild-failures flag");
        }

        unshift @selectors, split(/,\s*/, $moduleList);
    }

    # Everything else in cmdlineOptions should be OK to apply directly as a module
    # or context option by now.
    $ctx->setOption(%{$cmdlineGlobalOptions});

    # _readConfigurationOptions will add pending global opts to ctx while ensuring
    # returned modules/sets have any such options stripped out. It will also add
    # module-specific options to any returned modules/sets.
    my @optionModulesAndSets =
        _readConfigurationOptions($ctx, $fh, $cmdlineGlobalOptions, $deferredOptions);
    close $fh;

    # Check if we're supposed to drop into an interactive shell instead.  If so,
    # here's the stop off point.

    if (@startProgramAndArgs) {
        $ctx->setupEnvironment(); # Read options from set-env
        $ctx->commitEnvironmentChanges(); # Apply env options to environment
        _executeCommandLineProgram(@startProgramAndArgs); # noreturn
    }

    if (!isTesting()) {
        # Running in a test harness, avoid downloading metadata which will be
        # ignored in the test or making changes to git config
        ksb::Updater::Git::verifyGitConfig($ctx);
    }

    $self->_downloadKDEProjectMetadata(); # Uses test data automatically

    # The user might only want metadata to update to allow for a later
    # --pretend run, check for that here.
    if (exists $cmdlineGlobalOptions->{'metadata-only'}) {
        return;
    }

    # At this point we have our list of candidate modules / module-sets (as read in
    # from rc-file). The module sets have not been expanded into modules.
    # We also might have cmdline "selectors" to determine which modules or
    # module-sets to choose. First let's select module sets, and expand them.

    my @globalCmdlineArgs = keys %{$cmdlineGlobalOptions};
    my $commandLineModules = scalar @selectors;

    my $moduleResolver = ksb::ModuleResolver->new($ctx);
    $moduleResolver->setCmdlineOptions($cmdlineOptions);
    $moduleResolver->setDeferredOptions($deferredOptions);
    $moduleResolver->setInputModulesAndOptions(\@optionModulesAndSets);
    $moduleResolver->setIgnoredSelectors([keys %ignoredSelectors]);

    $self->_defineNewModuleFactory($moduleResolver);

    my @modules;
    if ($commandLineModules) {
        @modules = $moduleResolver->resolveSelectorsIntoModules(@selectors);
    }
    else {
        # Build everything in the rc-file, in the order specified.
        @modules = $moduleResolver->expandModuleSets(@optionModulesAndSets);
    }

    # If modules were on the command line then they are effectively forced to
    # process unless overridden by command line options as well. If phases
    # *were* overridden on the command line, then no update pass is required
    # (all modules already have correct phases)
    @modules = _updateModulePhases(@modules) unless $commandLineModules;

    # TODO: Verify this does anything still
    my $metadataModule = $ctx->getKDEProjectsMetadataModule();
    $ctx->addToIgnoreList($metadataModule->scm()->ignoredModules());

    # Remove modules that are explicitly blanked out in their branch-group
    # i.e. those modules where they *have* a branch-group, and it's set to
    # be empty ("").
    my $resolver = $ctx->moduleBranchGroupResolver();
    my $branchGroup = $ctx->effectiveBranchGroup();

    @modules = grep {
        my $branch = $_->isKDEProject()
            ? $resolver->findModuleBranch($_->fullProjectPath(), $branchGroup)
            : 1; # Just a placeholder truthy value
        whisper ("Removing ", $_->fullProjectPath(), " due to branch-group") if (defined $branch and !$branch);
        (!defined $branch or $branch); # This is the actual test
    } (@modules);

    my $moduleGraph = $self->_resolveModuleDependencyGraph(@modules);

    if (!$moduleGraph || !exists $moduleGraph->{graph}) {
        croak_runtime("Failed to resolve dependency graph");
    }

    if (exists $cmdlineGlobalOptions->{'dependency-tree'}) {
        my $depTreeCtx = {
            stack => [''],
            depth => 0,
            report => sub {
                print(@_, "\n");
            }
        };
        ksb::DependencyResolver::walkModuleDependencyTrees(
            $moduleGraph->{graph},
            \&_yieldModuleDependencyTreeEntry,
            $depTreeCtx,
            @modules
        );

        my $result = {
            dependencyInfo => $moduleGraph,
            selectedModules => [],
            build => 0
        };
        return $result;
    }

    @modules = ksb::DependencyResolver::sortModulesIntoBuildOrder(
        $moduleGraph->{graph}
    );

    # Filter --resume-foo options. This might be a second pass, but that should
    # be OK since there's nothing different going on from the first pass (in
    # resolveSelectorsIntoModules) in that event.
    @modules = _applyModuleFilters($ctx, @modules);

    # Check for ignored modules (post-expansion)
    @modules = grep {
        ! exists $ignoredSelectors{$_->name()} &&
        ! exists $ignoredSelectors{$_->moduleSet()->name() // ''}
    } @modules;

    if(exists $cmdlineGlobalOptions->{'list-build'}) {
        for my $module (@modules) {
            my $branch = ksb::DependencyResolver::_getBranchOf($module);
            print(' ── ', $module->name());
            if($branch) {
                print(' : ', $branch);
            }
            print("\n");
        }

        my $result = {
            dependencyInfo => $moduleGraph,
            selectedModules => [],
            build => 0
        };
        return $result;
    }

    my $result = {
        dependencyInfo => $moduleGraph,
        selectedModules => \@modules,
        build => 1
    };
    return $result;
}

# Causes kde-projects metadata to be downloaded (unless --pretend, --no-src, or
# --no-metadata is in effect, although we'll download even in --pretend if
# nothing is available).
#
# No return value.
sub _downloadKDEProjectMetadata
{
    my $self = shift;
    my $ctx = $self->context();
    my $updateStillNeeded = 0;

    my $wasPretending = pretending();

    eval {
        for my $metadataModule (
            $ctx->getKDEProjectsMetadataModule())
        {
            my $sourceDir = $metadataModule->getSourceDir();
            super_mkdir($sourceDir);

            my $moduleSource = $metadataModule->fullpath('source');
            my $updateDesired = !$ctx->getOption('no-metadata') && $ctx->phases()->has('update');
            my $updateNeeded = (! -e $moduleSource) || is_dir_empty($moduleSource);
            my $lastUpdate = $ctx->getPersistentOption('global', 'last-metadata-update') // 0;

            $updateStillNeeded ||= $updateNeeded;

            if (!$updateDesired && $updateNeeded && (time - ($lastUpdate)) >= 7200) {
                warning (" r[b[*] Skipping build metadata update, but it hasn't been updated recently!");
            }

            if ($updateNeeded && pretending()) {
                warning (" y[b[*] Ignoring y[b[--pretend] option to download required metadata\n" .
                         " y[b[*] --pretend mode will resume after metadata is available.");
                ksb::Debug::setPretending(0);
            }

            if ($updateDesired && (!pretending() || $updateNeeded)) {
                $metadataModule->scm()->updateInternal();
                $ctx->setPersistentOption('global', 'last-metadata-update', time);
            }

            ksb::Debug::setPretending($wasPretending);
        }
    };

    my $err = $@;

    ksb::Debug::setPretending($wasPretending);

    if ($err) {
        die $err if $updateStillNeeded;

        # Assume previously-updated metadata will work if not updating
        warning (" b[r[*] Unable to download required metadata for build process");
        warning (" b[r[*] Will attempt to press onward...");
        warning (" b[r[*] Exception message: $@");
    }
}

# Returns a graph of Modules according to the KDE project database dependency
# information.
#
# The sysadmin/repo-metadata repository must have already been updated, and the
# module factory must be setup. The modules for which to calculate the graph
# must be passed in as arguments
sub _resolveModuleDependencyGraph
{
    my $self = shift;
    my $ctx = $self->context();
    my $metadataModule = $ctx->getKDEProjectsMetadataModule();
    my @modules = @_;

    my $graph = eval {
        my $dependencyResolver = ksb::DependencyResolver->new($self->{module_factory});
        my $branchGroup = $ctx->effectiveBranchGroup();

        if (isTesting()) {
            my $testDeps = <<~END;
            juk: kcalc
            dolphin: konsole
            kdesrc-build: juk
            END

            open my $dependencies, '<', \$testDeps;
            debug (" -- Reading dependencies from test data");
            $dependencyResolver->readDependencyData($dependencies);
            close $dependencies;
        } else {
            my $srcdir = $metadataModule->fullpath('source');
            my $dependencies;

            my $dependencyFile = "$srcdir/dependencies/dependencies_v2-$branchGroup.json";
            if (-e $dependencyFile && exists $ENV{KDESRC_BUILD_BETA}) {
                $dependencies = pretend_open($dependencyFile)
                    or die "Unable to open $dependencyFile: $!";

                debug (" -- Reading dependencies from $dependencyFile");
                $dependencyResolver->readDependencyData_v2($dependencies);
            } else {
                $dependencyFile = "$srcdir/dependencies/dependency-data-$branchGroup";
                $dependencies = pretend_open($dependencyFile)
                    or die "Unable to open $dependencyFile: $!";

                debug (" -- Reading dependencies from $dependencyFile");
                $dependencyResolver->readDependencyData($dependencies);
            }

            close $dependencies;
        }

        $dependencyResolver->resolveToModuleGraph(@modules);
    };

    if ($@) {
        warning (" r[b[*] Problems encountered trying to determing correct module graph:");
        warning (" r[b[*] $@");
        warning (" r[b[*] Will attempt to continue.");

        $graph = {
            graph => undef,
            syntaxErrors  => 0,
            cycles        => 0,
            trivialCycles => 0,
            pathErrors    => 0,
            branchErrors  => 0,
            exception => $@
        };
    }
    else {
        if (!$graph->{graph}) {
            warning (" r[b[*] Unable to determine correct module graph");
            warning (" r[b[*] Will attempt to continue.");
        }
    }

    $graph->{exception} = undef;

    return $graph;
}

# Runs all update, build, install, etc. phases. Basically this *is* the
# script.
# The metadata module must already have performed its update by this point.
sub runAllModulePhases
{
    my $self = shift;
    my $ctx = $self->context();
    my @modules = $self->modules();

    if ($ctx->getOption('print-modules')) {
        for my $m (@modules) {
            say ((" " x ($m->getOption('#dependency-level', 'module') // 0)), "$m");
        }
        return 0; # Abort execution early!
    }

    # Add to global module list now that we've filtered everything.
    $ctx->addModule($_) foreach @modules;

    my $runMode = $self->runMode();

    if ($runMode eq 'query') {
        my $queryMode = $ctx->getOption('query', 'module');

        # Default to ->getOption as query method.
        # $_[0] is short name for first param.
        my $query = sub { $_[0]->getOption($queryMode) };
        $query = sub { $_[0]->fullpath('source') } if $queryMode eq 'source-dir';
        $query = sub { $_[0]->fullpath('build') }  if $queryMode eq 'build-dir';
        $query = sub { $_[0]->installationPath() } if $queryMode eq 'install-dir';
        $query = sub { $_[0]->fullProjectPath() }  if $queryMode eq 'project-path';
        $query = sub { ($_[0]->scm()->_determinePreferredCheckoutSource())[0] // '' }
            if $queryMode eq 'branch';

        if (@modules == 1) {
            # No leading module name, just the value
            say $query->($modules[0]);
        } else {
            for my $m (@modules) {
                say "$m: ", $query->($m);
            }
        }

        return 0;
    }

    my $result; # shell-style (0 == success)

    # If power-profiles-daemon is in use, request switching to performance mode.
    my $dbusConnection = $self->_holdPerformancePowerProfileIfPossible();

    if ($runMode eq 'build') {
        # build and (by default) install.  This will involve two simultaneous
        # processes performing update and build at the same time by default.

        # Check for absolutely essential programs now.
        if (!_checkForEssentialBuildPrograms($ctx) &&
            !exists $ENV{KDESRC_BUILD_IGNORE_MISSING_PROGRAMS})
        {
            error (<<DONE);
 r[b[*] Aborting now to save a lot of wasted time.
 y[b[*] export b[KDESRC_BUILD_IGNORE_MISSING_PROGRAMS=1] and re-run (perhaps with --no-src)
 r[b[*] to continue anyways. If this check was in error please report a bug against
 y[b[*] kdesrc-build at https://bugs.kde.org/
DONE
            $result = 1;
        } else {
            my $runner = ksb::TaskManager->new($self);
            $result = $runner->runAllTasks;
        }
    }
    elsif ($runMode eq 'install') {
        # install but do not build (... unless the buildsystem does that but
        # hey, we tried)
        $result = _handle_install ($ctx);
    }
    elsif ($runMode eq 'uninstall') {
        $result = _handle_uninstall ($ctx);
    }

    _cleanup_log_directory($ctx)
        if $ctx->getOption('purge-old-logs');

    # Prove that we can introduce an event loop, the sub won't run
    # until we start an event loop.
    Mojo::IOLoop->timer(0 => sub ($loop) {
        my $workLoad        = $self->workLoad();
        my $dependencyGraph = $workLoad->{dependencyInfo}->{graph};
        my $ctx             = $self->context();

        _output_failed_module_lists($ctx, $dependencyGraph);

        $loop->stop; # Stop waiting in I/O loop to resume main thread
    });

    Mojo::IOLoop->start; # start event loop and block until it is ended

    # Record all failed modules. Unlike the 'resume-list' option this doesn't
    # include any successfully-built modules in between failures.
    my $failedModules = join(',', map { "$_" } $ctx->listFailedModules());
    if ($failedModules) {
        # We don't clear the list of failed modules on success so that
        # someone can build one or two modules and still use
        # --rebuild-failures
        $ctx->setPersistentOption('global', 'last-failed-module-list', $failedModules);
    }

    # env driver is just the ~/.config/kde-env-*.sh, session driver is that + ~/.xsession
    if ($ctx->getOption('install-environment-driver') ||
        $ctx->getOption('install-session-driver'))
    {
        _installCustomSessionDriver($ctx);
    }

    # Check for post-build messages and list them here
    for my $m (@modules) {
        my @msgs = $m->getPostBuildMessages();

        next unless @msgs;

        warning("\ny[Important notification for b[$m]:");
        warning("    $_") foreach @msgs;
    }

    my $color = 'g[b[';
    $color = 'r[b[' if $result;

    info ("\n${color}", $result ? ":-(" : ":-)") unless pretending();

    return $result;
}

# Method: finish
#
# Exits the script cleanly, including removing any lock files created.
#
# Parameters:
#  [exit] - Optional; if passed, is used as the exit code, otherwise 0 is used.
sub finish ($self, $exitcode = 0)
{
    my $ctx = $self->context();

    if (pretending() || $self->{_base_pid} != $$) {
        # Abort early if pretending or if we're not the same process
        # that was started by the user (e.g. async mode, forked pipe-opens
        exit $exitcode;
    }

    $ctx->closeLock();
    $ctx->storePersistentOptions();

    # modules in different source dirs may have different log dirs. If there
    # are multiple, show them all.

    my $globalLogBase = $ctx->getSubdirPath('log-dir');
    my $globalLogDir  = $ctx->getLogDir();
    # global first
    note ("Your logs are saved in file://y[$globalLogDir]");

    while((my $base, my $log) = each %{$ctx->{logPaths}}) {
        note ("  (additional logs are saved in file://y[$log])")
            if $base ne $globalLogBase;
    }

    exit $exitcode;
}

### Package-internal helper functions.

# Reads a "line" from a file. This line is stripped of comments and extraneous
# whitespace. Also, backslash-continued multiple lines are merged into a single
# line.
#
# First parameter is the reference to the filehandle to read from.
# Returns the text of the line.
sub _readNextLogicalLine
{
    my $fileReader = shift;

    while($_ = $fileReader->readLine()) {
        # Remove trailing newline
        chomp;

        # Replace \ followed by optional space at EOL and try again.
        if(s/\\\s*$//)
        {
            $_ .= $fileReader->readLine();
            redo;
        }

        s/#.*$//;        # Remove comments
        next if /^\s*$/; # Skip blank lines

        return $_;
    }

    return undef;
}

# Takes an input line, and extracts it into an option name, and simplified
# value. The value has "false" converted to 0, white space simplified (like in
# Qt), and tildes (~) in what appear to be path-like entries are converted to
# the home directory path.
#
# First parameter is the build context (used for translating option values).
# Second parameter is the line to split.
# Return value is (option-name, option-value)
sub _splitOptionAndValue
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $input = shift;
    my $fileName = shift->currentFilename();
    my $optionRE = qr/\$\{([a-zA-Z0-9-]+)\}/;

    # The option is the first word, followed by the
    # flags on the rest of the line.  The interpretation
    # of the flags is dependent on the option.
    my ($option, $value) = ($input =~ /^\s*     # Find all spaces
                            ([-\w]+) # First match, alphanumeric, -, and _
                            # (?: ) means non-capturing group, so (.*) is $value
                            # So, skip spaces and pick up the rest of the line.
                            (?:\s+(.*))?$/x);

    $value = Mojo::Util::trim($value // '');

    # Simplify whitespace.
    $value =~ s/\s+/ /g;

    # Check for false keyword and convert it to Perl false.
    $value = 0 if lc($value) eq 'false';

    # Replace reference to global option with their value.
    # The regex basically just matches ${option-name}.
    my ($sub_var_name) = ($value =~ $optionRE);
    while ($sub_var_name)
    {
        my $sub_var_value = $ctx->getOption($sub_var_name) || '';
        if(!$ctx->hasOption($sub_var_name)) {
            warning (" *\n * WARNING: $sub_var_name is not set at y[$fileName:$.]\n *");
        }

        debug ("Substituting \${$sub_var_name} with $sub_var_value");

        $value =~ s/\$\{$sub_var_name\}/$sub_var_value/g;

        # Replace other references as well.  Keep this RE up to date with
        # the other one.
        ($sub_var_name) = ($value =~ $optionRE);
    }

    # Replace tildes with home directory.
    1 while ($value =~ s"(^|:|=)~/"$1$ENV{'HOME'}/");

    return ($option, $value);
}

# Ensures that the given ModuleSet has at least a valid repository and
# use-modules setting based on the given BuildContext.
sub _validateModuleSet
{
    my ($ctx, $moduleSet) = @_;
    my $name = $moduleSet->name() || 'unnamed';
    my $rcSources = _getModuleSources($moduleSet);

    # re-read option from module set since it may be pre-set
    my $selectedRepo = $moduleSet->getOption('repository');
    if (!$selectedRepo) {
        error (<<EOF);

There was no repository selected for the y[b[$name] module-set declared at
    $rcSources

A repository is needed to determine where to download the source code from.

Most will want to use the b[g[kde-projects] repository. See also
https://docs.kde.org/?application=kdesrc-build&branch=trunk5&path=kde-modules-and-selection.html#module-sets
EOF
        die make_exception('Config', 'Missing repository option');
    }

    my $repoSet = $ctx->getOption('git-repository-base');
    if ($selectedRepo ne KDE_PROJECT_ID && $selectedRepo ne QT_PROJECT_ID &&
        not exists $repoSet->{$selectedRepo})
    {
        my $projectID = KDE_PROJECT_ID;
        my $moduleSetName = $moduleSet->name();
        my $moduleSetId = $moduleSetName ? "module-set ($moduleSetName)"
                                         : "module-set";

        error (<<EOF);
There is no repository assigned to y[b[$selectedRepo] when assigning a
$moduleSetId at $rcSources.

These repositories are defined by g[b[git-repository-base] in the global
section of your configuration.

Make sure you spelled your repository name right, but you probably meant
to use the magic b[$projectID] repository for your module-set instead.
EOF

        die make_exception('Config', 'Unknown repository base');
    }
}

# Reads in the options from the config file and adds them to the option store.
# The first parameter is a BuildContext object to use for creating the returned
#     ksb::Module under.
# The second parameter is a reference to the file handle to read from.
# The third parameter is the ksb::OptionsBase to use (module, module-set, ctx,
#     etc.)
#     For global options, just pass in the BuildContext for this param.
# The fourth parameter is optional, if provided it should be a regexp for the
#     terminator to use for the block being parsed in the rc file.
#
# The return value is the ksb::OptionsBase provided, with options set as given in
# the configuration file section being processed.
sub _parseModuleOptions ($ctx, $fileReader, $module, $endRE=undef)
{
    assert_isa($module, 'ksb::OptionsBase');

    state $moduleID = 0;
    my $endWord = $module->isa('ksb::BuildContext') ? 'global'     :
                  $module->isa('ksb::ModuleSet')    ? 'module-set' :
                  $module->isa('ksb::Module')       ? 'module'     :
                                                      'options';

    # Just look for an end marker if terminator not provided.
    $endRE //= qr/^end[\w\s]*$/;

    _markModuleSource($module, $fileReader->currentFilename() . ":$.");
    $module->setOption('#entry_num', $moduleID++);

    # Read in each option
    while (($_ = _readNextLogicalLine($fileReader)) && ($_ !~ $endRE))
    {
        my $current_file = $fileReader->currentFilename();

        # Sanity check, make sure the section is correctly terminated
        if(/^(module\b|options\b)/)
        {
            error ("Invalid configuration file $current_file at line $.\nAdd an 'end $endWord' before " .
                   "starting a new module.\n");
            die make_exception('Config', "Invalid file $current_file");
        }

        my ($option, $value) = _splitOptionAndValue($ctx, $_, $fileReader);

        eval { $module->setOption($option, $value); };
        if (my $err = $@) {
            if (blessed($err) && $err->isa('ksb::BuildException::Config'))
            {
                my $msg = "$current_file:$.: " . $err->message();
                my $explanation = $err->optionUsageExplanation();
                $msg = $msg . "\n" . $explanation if $explanation;
                $err->setMessage($msg);
            }

            die; # re-throw
        }
    }

    return $module;
}

# Marks the given OptionsBase subclass (i.e. Module or ModuleSet) as being
# read in from the given string (filename:line). An OptionsBase can be
# tagged under multiple files.
sub _markModuleSource
{
    my ($optionsBase, $configSource) = @_;
    my $key = '#defined-at';

    my $sourcesRef = $optionsBase->hasOption($key)
        ? $optionsBase->getOption($key)
        : [];

    push @$sourcesRef, $configSource;
    $optionsBase->setOption($key, $sourcesRef);
}

# Returns rcfile sources for given OptionsBase (comma-separated).
sub _getModuleSources
{
    my $optionsBase = shift;
    my $key = '#defined-at';

    my $sourcesRef = $optionsBase->getOption($key) || [];

    return join(', ', @$sourcesRef);
}

# Reads in a "moduleset".
#
# First parameter is the build context.
# Second parameter is the filehandle to the config file to read from.
# Third parameter is the ksb::ModuleSet to use.
#
# Returns the ksb::ModuleSet passed in with read-in options set, which may need
# to be further expanded (see ksb::ModuleSet::convertToModules).
sub _parseModuleSetOptions
{
    my ($ctx, $fileReader, $moduleSet) = @_;

    $moduleSet = _parseModuleOptions($ctx, $fileReader, $moduleSet, qr/^end\s+module(-?set)?$/);

    # Perl-specific note! re-blessing the module set into the right 'class'
    # You'd probably have to construct an entirely new object and copy the
    # members over in other languages.
    if ($moduleSet->getOption('repository') eq KDE_PROJECT_ID) {
        bless $moduleSet, 'ksb::ModuleSet::KDEProjects';
    } elsif ($moduleSet->getOption('repository') eq QT_PROJECT_ID) {
        bless $moduleSet, 'ksb::ModuleSet::Qt';
    }

    return $moduleSet;
}

# Function: _readConfigurationOptions
#
# Reads in the settings from the configuration, passed in as an open
# filehandle.
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  ctx - The <BuildContext> to update based on the configuration read and
#  any pending command-line options (see cmdlineGlobalOptions).
#
#  filehandle - The I/O object to read from. Must handle _eof_ and _readline_
#  methods (e.g. <IO::Handle> subclass).
#
#  cmdlineGlobalOptions - An input hashref mapping command line options to their
#  values (if any), so that these may override conflicting entries in the rc-file
#
#  deferredOptions - An out parameter: a listref containing hashrefs mapping
#  module names to options set by any 'options' blocks read in by this function.
#  Each key (identified by the name of the 'options' block) will point to a
#  hashref value holding the options to apply.
#
# Returns:
#  @module - Heterogeneous list of <Modules> and <ModuleSets> defined in the
#  configuration file. No module sets will have been expanded out (either
#  kde-projects or standard sets).
#
# Throws:
#  - Config exceptions.
sub _readConfigurationOptions ($ctx, $fh, $cmdlineGlobalOptions, $deferredOptionsRef)
{
    my @module_list;
    my $rcfile = $ctx->rcFile();
    my ($option, %readModules);

    my $fileReader = ksb::RecursiveFH->new($rcfile);
    $fileReader->addFile($fh, $rcfile);

    # Read in global settings
    while ($_ = $fileReader->readLine())
    {
        s/#.*$//; # Remove comments
        s/^\s+//; # Remove leading whitespace
        next unless $_; # Skip blank lines

        # First command in .kdesrc-buildrc should be a global
        # options declaration, even if none are defined.
        if (not /^global\s*$/)
        {
            error ("Invalid configuration file: $rcfile.");
            error ("Expecting global settings section at b[r[line $.]!");
            die make_exception('Config', 'Missing global section');
        }

        # Now read in each global option.
        my $globalOpts = _parseModuleOptions($ctx, $fileReader, ksb::OptionsBase->new());

        # Remove any cmdline options so they don't overwrite build context
        delete @{$globalOpts->{options}}{keys %{$cmdlineGlobalOptions}};
        $ctx->mergeOptionsFrom($globalOpts);

        last;
    }

    my $using_default = 1;
    my $creation_order = 0;
    my %seenModules; # NOTE! *not* module-sets, *just* modules.
    my %seenModuleSets; # and vice versa -- named sets only though!
    my %seenModuleSetItems; # To track option override modules.

    # Now read in module settings
    while ($_ = $fileReader->readLine())
    {
        s/#.*$//;          # Remove comments
        s/^\s*//;          # Remove leading whitespace
        next if (/^\s*$/); # Skip blank lines

        # Get modulename (has dash, dots, slashes, or letters/numbers)
        my ($type, $modulename) = /^(options|module)\s+([-\/\.\w]+)\s*$/;
        my $newModule;

        # 'include' directives can change the current file, so check where we're at
        $rcfile = $fileReader->currentFilename();

        # Module-set?
        if (not $modulename) {
            my $moduleSetRE = qr/^module-set\s*([-\/\.\w]+)?\s*$/;
            ($modulename) = m/$moduleSetRE/;

            # modulename may be blank -- use the regex directly to match
            if (not /$moduleSetRE/) {
                error ("Invalid configuration file $rcfile!");
                error ("Expecting a start of module section at r[b[line $.].");
                die make_exception('Config', 'Ungrouped/Unknown option');
            }

            if ($modulename && exists $seenModuleSets{$modulename}) {
                error ("Duplicate module-set $modulename at $rcfile:$.");
                die make_exception('Config', "Duplicate module-set $modulename defined at $rcfile:$.");
            }

            if ($modulename && exists $seenModules{$modulename}) {
                error ("Name $modulename for module-set at $rcfile:$. is already in use on a module");
                die make_exception('Config', "Can't re-use name $modulename for module-set defined at $rcfile:$.");
            }

            # A moduleset can give us more than one module to add.
            $newModule = _parseModuleSetOptions($ctx, $fileReader,
                ksb::ModuleSet->new($ctx, $modulename || "Unnamed module-set at $rcfile:$."));
            $newModule->{'#create-id'} = ++$creation_order;

            # Save 'use-modules' entries so we can see if later module decls
            # are overriding/overlaying their options.
            my @moduleSetItems = $newModule->moduleNamesToFind();
            @seenModuleSetItems{@moduleSetItems} = ($newModule) x scalar @moduleSetItems;

            # Reserve enough 'create IDs' for all named modules to use
            $creation_order += scalar @moduleSetItems;

            $seenModuleSets{$modulename} = $newModule if $modulename;
        }
        # Duplicate module entry? (Note, this must be checked before the check
        # below for 'options' sets)
        elsif (exists $seenModules{$modulename} && $type ne 'options') {
            error ("Duplicate module declaration b[r[$modulename] on line $. of $rcfile");
            die make_exception('Config', "Duplicate module $modulename declared at $rcfile:$.");
        }
        # Module/module-set options overrides
        elsif ($type eq 'options') {
            my $options = _parseModuleOptions($ctx, $fileReader,
                ksb::OptionsBase->new());

            push @{$deferredOptionsRef}, {
                name => $modulename,
                opts => $options->{options},
            };

            # NOTE: There is no duplicate options block checking here, and we
            # now currently rely on there being no duplicate checks to allow
            # for things like kf5-common-options.ksb to be included
            # multiple times.

            next; # Don't add to module list
        }
        # Must follow 'options' handling
        elsif (exists $seenModuleSets{$modulename}) {
            error ("Name $modulename for module at $rcfile:$. is already in use on a module-set");
            die make_exception('Config', "Can't re-use name $modulename for module defined at $rcfile:$.");
        }
        else {
            $newModule = _parseModuleOptions($ctx, $fileReader,
                ksb::Module->new($ctx, $modulename));
            $newModule->{'#create-id'} = ++$creation_order;
            $seenModules{$modulename} = $newModule;
        }

        push @module_list, $newModule;

        $using_default = 0;
    }

    while (my ($name, $moduleSet) = each %seenModuleSets) {
        _validateModuleSet($ctx, $moduleSet);
    }

    # If the user doesn't ask to build any modules, build a default set.
    # The good question is what exactly should be built, but oh well.
    if ($using_default) {
        warning (" b[y[*] There do not seem to be any modules to build in your configuration.");
        return ();
    }

    return @module_list;
}

# Exits out of kdesrc-build, executing the user's preferred shell instead.  The
# difference is that the environment variables should be as set in kdesrc-build
# instead of as read from .bashrc and friends.
#
# You should pass in the options to run the program with as a list.
#
# Meant to implement the --run command line option.
sub _executeCommandLineProgram
{
    my ($program, @args) = @_;

    if (!$program)
    {
        error ("You need to specify a program with the --run option.");
        exit 1; # Can't use finish here.
    }

    if (($< != $>) && ($> == 0))
    {
        error ("kdesrc-build will not run a program as root unless you really are root.");
        exit 1;
    }

    debug ("Executing b[r[$program] ", join(' ', @args));

    exit 0 if pretending();

    exec $program, @args or do {
        # If we get to here, that sucks, but don't continue.
        error ("Error executing $program: $!");
        exit 1;
    };
}

# Function: _handle_install
#
# Handles the installation process.  Simply calls 'make install' in the build
# directory, though there is also provision for cleaning the build directory
# afterwards, or stopping immediately if there is a build failure (normally
# every built module is attempted to be installed).
#
# Parameters:
# 1. Build Context, from which the install list is generated.
#
# Return value is a shell-style success code (0 == success)
sub _handle_install
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my @modules = $ctx->modulesInPhase('install');

    @modules = grep { $_->buildSystem()->needsInstalled() } (@modules);
    my $result = 0;

    for my $module (@modules)
    {
        $ctx->resetEnvironment();
        $result = $module->install() || $result;

        if ($result && $module->getOption('stop-on-failure')) {
            note ("y[Stopping here].");
            return 1; # Error
        }
    }

    return $result;
}

# Function: _handle_uninstall
#
# Handles the uninstal process.  Simply calls 'make uninstall' in the build
# directory, while assuming that Qt or CMake actually handles it.
#
# The order of the modules is often significant, and it may work better to
# uninstall modules in reverse order from how they were installed. However this
# code does not automatically reverse the order; modules are uninstalled in the
# order determined by the build context.
#
# This function obeys the 'stop-on-failure' option supported by _handle_install.
#
# Parameters:
# 1. Build Context, from which the uninstall list is generated.
#
# Return value is a shell-style success code (0 == success)
sub _handle_uninstall
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my @modules = $ctx->modulesInPhase('uninstall');

    @modules = grep { $_->buildSystem()->needsInstalled() } (@modules);
    my $result = 0;

    for my $module (@modules)
    {
        $ctx->resetEnvironment();
        $result = $module->uninstall() || $result;

        if ($result && $module->getOption('stop-on-failure'))
        {
            note ("y[Stopping here].");
            return 1; # Error
        }
    }

    return $result;
}

# Function: _applyModuleFilters
#
# Applies any module-specific filtering that is necessary after reading command
# line and rc-file options. (This is as opposed to phase filters, which leave
# each module as-is but change the phases they operate as part of, this
# function could remove a module entirely from the build).
#
# Used for --resume-{from,after} and --stop-{before,after}, but more could be
# added in theory.
# This subroutine supports --{resume,stop}-* for both modules and module-sets.
#
# Parameters:
#  ctx - <BuildContext> in use.
#  @modules - List of <Modules> or <ModuleSets> to apply filters on.
#
# Returns:
#  list of <Modules> or <ModuleSets> with any inclusion/exclusion filters
#  applied. Do not assume this list will be a strict subset of the input list,
#  however the order will not change amongst the input modules.
sub _applyModuleFilters
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my @moduleList = @_;

    if (!$ctx->getOption('resume-from') && !$ctx->getOption('resume-after') &&
        !$ctx->getOption('stop-before') && !$ctx->getOption('stop-after'))
    {
        debug ("No command-line filter seems to be present.");
        return @moduleList;
    }

    if ($ctx->getOption('resume-from') && $ctx->getOption('resume-after'))
    {
        # This one's an error.
        error (<<EOF);
You specified both r[b[--resume-from] and r[b[--resume-after] but you can only
use one.
EOF

        croak_runtime("Both --resume-after and --resume-from specified.");
    }

    if ($ctx->getOption('stop-before') && $ctx->getOption('stop-after'))
    {
        # This one's an error.
        error (<<EOF);
You specified both r[b[--stop-before] and r[b[--stop-after] but you can only
use one.
EOF

        croak_runtime("Both --stop-before and --stop-from specified.");
    }

    return unless @moduleList; # Empty input?

    my $resumePoint = $ctx->getOption('resume-from') ||
                      $ctx->getOption('resume-after');

    my $startIndex = scalar @moduleList;

    if ($resumePoint) {
        debug ("Looking for $resumePoint for --resume-* option");

        # || 0 is a hack to force Boolean context.
        my $filterInclusive = $ctx->getOption('resume-from') || 0;
        my $found = 0;

        for (my $i = 0; $i < scalar @moduleList; $i++) {
            my $module = $moduleList[$i];

            $found = $module->name() eq $resumePoint;
            if ($found) {
                $startIndex = $filterInclusive ? $i : $i + 1;
                $startIndex = min($startIndex, scalar @moduleList - 1);
                last;
            }
        }
    }
    else {
        $startIndex = 0;
    }

    my $stopPoint = $ctx->getOption('stop-before') ||
                    $ctx->getOption('stop-after');

    my $stopIndex = 0;

    if ($stopPoint) {
        debug ("Looking for $stopPoint for --stop-* option");

        # || 0 is a hack to force Boolean context.
        my $filterInclusive = $ctx->getOption('stop-before') || 0;
        my $found = 0;

        for (my $i = $startIndex; $i < scalar @moduleList; $i++) {
            my $module = $moduleList[$i];

            $found = $module->name() eq $stopPoint;
            if ($found) {
                $stopIndex = $i - ($filterInclusive ? 1 : 0);
                last;
            }
        }
    }
    else {
        $stopIndex = scalar @moduleList - 1;
    }

    if ($startIndex > $stopIndex || scalar @moduleList == 0) {
        # Lost all modules somehow.
        croak_runtime("Unknown resume -> stop point $resumePoint -> $stopPoint.");
    }

    return @moduleList[$startIndex .. $stopIndex];
}

# This defines the factory function needed for lower-level code to properly be
# able to create ksb::Module objects from just the module name, while still
# having the options be properly set and having the module properly tied into a
# context.
sub _defineNewModuleFactory
{
    my ($self, $resolver) = @_;
    my $ctx = $self->context();

    $self->{module_factory} = sub {
        # We used to need a special module-set to ignore virtual deps (they
        # would throw errors if the name did not exist). But, the resolver
        # handles that fine as well.
        return $resolver->resolveModuleIfPresent(shift);
    };
}

# Updates the built-in phase list for all Modules passed into this function in
# accordance with the options set by the user.
sub _updateModulePhases
{
    whisper ("Filtering out module phases.");
    for my $module (@_) {
        if ($module->getOption('manual-update') ||
            $module->getOption('no-src'))
        {
            $module->phases()->clear();
            next;
        }

        if ($module->getOption('manual-build')) {
            $module->phases()->filterOutPhase('build');
            $module->phases()->filterOutPhase('test');
            $module->phases()->filterOutPhase('install');
        }

        $module->phases()->filterOutPhase('install') unless $module->getOption('install-after-build');
        $module->phases()->addPhase('test') if $module->getOption('run-tests');
    }

    return @_;
}

# Function: _cleanup_log_directory
#
# This function removes log directories from old kdesrc-build runs.  All log
# directories not referenced by $log_dir/latest somehow are made to go away.
#
# Parameters:
# 1. Build context.
#
# No return value.
sub _cleanup_log_directory
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $logdir = $ctx->getSubdirPath('log-dir');

    return 0 if ! -e "$logdir/latest"; # Could happen for error on first run...

    # This glob relies on the date being in the specific format YYYY-MM-DD-ID
    my @dirs = bsd_glob("$logdir/????-??-??-??/", GLOB_NOSORT);

    my %needed_table;
    for my $trackedLogDir ("$logdir/latest", "$logdir/latest-by-phase") {
        next unless -d $trackedLogDir;
        my @needed = _reachableModuleLogs($trackedLogDir);

        # Convert a list to a hash lookup since Perl lacks a "list-has"
        @needed_table{@needed} = (1) x @needed;
    }

    my $length = scalar @dirs - scalar keys %needed_table;
    whisper ("Removing g[b[$length] out of g[b[$#dirs] old log directories...");

    for my $dir (@dirs) {
        my ($id) = ($dir =~ m/(\d\d\d\d-\d\d-\d\d-\d\d)/);
        safe_rmtree($dir) unless $needed_table{$id};
    }
}

# Function: _output_possible_solution
#
# Print out a "possible solution" message.
# It will display a list of command lines to run.
#
# No message is printed out if the list of failed modules is empty, so this
# function can be called unconditionally.
#
# Parameters:
# 1. Build Context
# 2. List of ksb::Modules that had failed to build/configure/cmake.
#
# No return value.
sub _output_possible_solution
{
    my ($ctx, @fail_list) = @_;
    assert_isa($ctx, 'ksb::BuildContext');

    return unless @fail_list;
    return unless not pretending();

    my @moduleNames = ();

    for my $module (@fail_list) {
        my $logfile = $module->getOption('#error-log-file');

        if (($logfile =~ m"/cmake\.log$") or ($logfile =~ m"/meson\-setup\.log$")) {
            push @moduleNames, $module->name();
        }
    }

    if (scalar(@moduleNames) > 0) {
        my $names = join(', ', @fail_list);
        warning ("
Possible solution: Install the build dependencies for the modules:
$names
You can use 'sudo apt build-dep <source_package>', 'sudo dnf builddep <package>', 'sudo zypper --plus-content repo-source source-install --build-deps-only <source_package>' or a similar command for your distro of choice.
See https://community.kde.org/Get_Involved/development/Install_the_dependencies");
    }
}

# Function: _output_failed_module_list
#
# Print out an error message, and a list of modules that match that error
# message.  It will also display the log file name if one can be determined.
# The message will be displayed all in uppercase, with PACKAGES prepended, so
# all you have to do is give a descriptive message of what this list of
# packages failed at doing.
#
# No message is printed out if the list of failed modules is empty, so this
# function can be called unconditionally.
#
# Parameters:
# 1. Build Context
# 2. Message to print (e.g. 'failed to foo')
# 3. List of ksb::Modules that had failed to foo
#
# No return value.
sub _output_failed_module_list
{
    my ($ctx, $message, @fail_list) = @_;
    assert_isa($ctx, 'ksb::BuildContext');

    $message = uc $message; # Be annoying

    return unless @fail_list;

    debug ("Message is $message");
    debug ("\tfor ", join(', ', @fail_list));

    my $homedir = $ENV{'HOME'};
    my $logfile;

    warning ("\nr[b[<<<  PACKAGES $message  >>>]");

    for my $module (@fail_list)
    {
        $logfile = $module->getOption('#error-log-file');

        # async updates may cause us not to have a error log file stored.  There's only
        # one place it should be though, take advantage of side-effect of log_command()
        # to find it.
        if (not $logfile) {
            my $logdir = $module->getLogDir() . "/error.log";
            $logfile = $logdir if -e $logdir;
        }

        $logfile = "No log file" unless $logfile;
        $logfile = "file://${logfile}";

        warning ("r[$module]") if pretending();
        warning ("r[$module] - g[$logfile]") if not pretending();
    }
}

# Function: _output_failed_module_lists
#
# This subroutine reads the list of failed modules for each phase in the build
# context and calls _output_failed_module_list for all the module failures.
#
# Parameters:
# 1. Build context
#
# Return value:
# None
sub _output_failed_module_lists
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $moduleGraph = shift;

    my $extraDebugInfo = {
        phases => {},
        failCount => {}
    };
    my @actualFailures = ();

    # This list should correspond to the possible phase names (although
    # it doesn't yet since the old code didn't, TODO)
    for my $phase ($ctx->phases()->phases())
    {
        my @failures = $ctx->failedModulesInPhase($phase);
        for my $failure (@failures) {
            # we already tagged the failure before, should not happen but
            # make sure to check to avoid spurious duplicate output
            next if $extraDebugInfo->{phases}->{$failure};

            $extraDebugInfo->{phases}->{$failure} = $phase;
            push @actualFailures, $failure;
        }
        _output_failed_module_list($ctx, "failed to $phase", @failures);
    }

    # See if any modules fail continuously and warn specifically for them.
    my @super_fail = grep {
        ($_->getPersistentOption('failure-count') // 0) > 3
    } (@{$ctx->moduleList()});

    foreach my $m (@super_fail)
    {
        # These messages will print immediately after this function completes.
        my $num_failures = $m->getPersistentOption('failure-count');

        $m->addPostBuildMessage("y[$m] has failed to build b[$num_failures] times.");
    }

    my $top = 5;
    my $numSuggestedModules = scalar @actualFailures;
    #
    # Omit listing $top modules if there are that many or fewer anyway.
    # Not much point ranking 4 out of 4 failures,
    # this feature is meant for 5 out of 65
    #
    if ($numSuggestedModules > $top) {
        my @sortedForDebug = ksb::DebugOrderHints::sortFailuresInDebugOrder(
            $moduleGraph,
            $extraDebugInfo,
            \@actualFailures
        );

        info ("\nThe following top $top may be the most important to fix to " .
            "get the build to work, listed in order of 'probably most " .
            "interesting' to 'probably least interesting' failure:\n");
        info ("\tr[b[$_]") foreach (@sortedForDebug[0..($top - 1)]);
    }

    _output_possible_solution($ctx, @actualFailures);
}

# Function: _installTemplatedFile
#
# This function takes a given file and a build context, and installs it to a
# given location while expanding out template entries within the source file.
#
# The template language is *extremely* simple: <% foo %> is replaced entirely
# with the result of $ctx->getOption(foo, 'no-inherit'). If the result
# evaluates false for any reason than an exception is thrown. No quoting of
# any sort is used in the result, and there is no way to prevent expansion of
# something that resembles the template format.
#
# Multiple template entries on a line will be replaced.
#
# The destination file will be created if it does not exist. If the file
# already exists then an exception will be thrown.
#
# Error handling: Any errors will result in an exception being thrown.
#
# Parameters:
# 1. Pathname to the source file (use absolute paths)
# 2. Pathname to the destination file (use absolute paths)
# 3. Build context to use for looking up template values
#
# Return value: There is no return value.
sub _installTemplatedFile
{
    my ($sourcePath, $destinationPath, $ctx) = @_;
    assert_isa($ctx, 'ksb::BuildContext');

    open (my $input,  '<', $sourcePath) or
        croak_runtime("Unable to open template source $sourcePath: $!");
    open (my $output, '>', $destinationPath) or
        croak_runtime("Unable to open template output $destinationPath: $!");

    while (!eof ($input)) {
        my $line = readline($input);
        if (!defined ($line)) {
            croak_runtime("Failed to read from $sourcePath at line $.: $!");
            unlink($destinationPath);
        }

        # Some lines should only be present in the source as they aid with testing.
        next if $line =~ /kdesrc-build: filter/;

        $line =~
            s {
                <% \s*    # Template bracket and whitespace
                ([^\s%]+) # Capture variable name
                \s*%>     # remaining whitespace and closing bracket
              }
              {
                  $ctx->getOption($1, 'module') //
                      croak_runtime("Invalid variable $1")
              }gxe;
              # Replace all matching expressions, use extended regexp w/
              # comments, and replacement is Perl code to execute.

        (print $output $line) or
            croak_runtime("Unable to write line to $destinationPath at line $.: $!");
    }
}

# Function: _installCustomFile
#
# This function installs a source file to a destination path, assuming the
# source file is a "templated" source file (see also _installTemplatedFile), and
# records a digest of the file actually installed. This function will overwrite
# a destination if the destination is identical to the last-installed file.
#
# Error handling: Any errors will result in an exception being thrown.
#
# Parameters:
# 1. Build context to use for looking up template values,
# 2. The full path to the source file.
# 3. The full path to the destination file (incl. name)
# 4. The key name to use for searching/recording installed MD5 digest.
#
# Return value: There is no return value.
sub _installCustomFile ($ctx, $sourceFilePath, $destFilePath, $md5KeyName)
{
    assert_isa($ctx, 'ksb::BuildContext');
    my $baseName = basename($sourceFilePath);

    if (-e $destFilePath) {
        my $existingMD5 = $ctx->getPersistentOption('/digests', $md5KeyName) // '';

        if (file_digest_md5($destFilePath) ne $existingMD5) {
            if (!$ctx->getOption('#delete-my-settings')) {
                error ("\tr[*] Installing \"b[$baseName]\" would overwrite an existing file:");
                error ("\tr[*]  y[b[$destFilePath]");
                error ("\tr[*] If this is acceptable, please delete the existing file and re-run,");
                error ("\tr[*] or pass b[--delete-my-settings] and re-run.");

                return;
            } elsif (!pretending()) {
                File::Copy::copy ($destFilePath, "$destFilePath.kdesrc-build-backup");
            }
        }
    }

    if (!pretending()) {
        _installTemplatedFile($sourceFilePath, $destFilePath, $ctx);
        $ctx->setPersistentOption('/digests', $md5KeyName, file_digest_md5($destFilePath));
    }
}

# Function: _installCustomSessionDriver
#
# This function installs the included sample .xsession and environment variable
# setup files, and records the md5sum of the installed results.
#
# If a file already exists, then its md5sum is taken and if the same as what
# was previously installed, is overwritten. If not the same, the original file
# is left in place and the .xsession is instead installed to
# .xsession-kdesrc-build
#
# Error handling: Any errors will result in an exception being thrown.
#
# Parameters:
# 1. Build context to use for looking up template values,
#
# Return value: There is no return value.
sub _installCustomSessionDriver
{
    use FindBin qw($RealBin);
    use List::Util qw(first);
    use File::Copy qw(copy);

    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my @xdgDataDirs = split(':', $ENV{XDG_DATA_DIRS} || '/usr/local/share/:/usr/share/');
    my $xdgDataHome = $ENV{XDG_DATA_HOME} || "$ENV{HOME}/.local/share";

    # First we have to find the source
    my @searchPaths = ($RealBin, map { "$_/apps/kdesrc-build" } ($xdgDataHome, @xdgDataDirs));

    s{/+$}{}   foreach @searchPaths; # Remove trailing slashes
    s{//+}{/}g foreach @searchPaths; # Remove duplicate slashes

    my $envScript = first { -f $_ } (
        map { "$_/data/kde-env-master.sh.in" } @searchPaths
    );
    my $sessionScript = first { -f $_ } (
        map { "$_/data/xsession.sh.in" } @searchPaths
    );

    if (!$envScript || !$sessionScript) {
        warning ("b[*] Unable to find helper files to setup a login session.");
        warning ("b[*] You will have to setup login yourself, or install kdesrc-build properly.");
        return;
    }

    my $destDir = $ENV{XDG_CONFIG_HOME} || "$ENV{HOME}/.config";
    super_mkdir($destDir) unless -d $destDir;

    _installCustomFile($ctx, $envScript, "$destDir/kde-env-master.sh",
        'kde-env-master-digest');
    _installCustomFile($ctx, $sessionScript, "$ENV{HOME}/.xsession",
        'xsession-digest') if $ctx->getOption('install-session-driver');

    if (!pretending()) {
        if ($ctx->getOption('install-session-driver') && !chmod (0744, "$ENV{HOME}/.xsession")) {
            error ("\tb[r[*] Error making b[~/.xsession] executable: $!");
            error ("\tb[r[*] If this file is not executable you may not be able to login!");
        };
    }
}

# Function: _checkForEssentialBuildPrograms
#
# This subroutine checks for programs which are absolutely essential to the
# *build* process and returns false if they are not all present. Right now this
# just means qmake and cmake (although this depends on what modules are
# actually present in the build context).
#
# Parameters:
# 1. Build context
#
# Return value:
# None
sub _checkForEssentialBuildPrograms
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $kdedir = $ctx->getOption('kdedir');
    my $qtdir = $ctx->getOption('qtdir');
    my @preferred_paths = ("$kdedir/bin", "$qtdir/bin");

    return 1 if pretending();

    my @buildModules = $ctx->modulesInPhase('build');
    my %requiredPrograms;
    my %modulesRequiringProgram;

    foreach my $module ($ctx->modulesInPhase('build')) {
        my @progs = $module->buildSystem()->requiredPrograms();

        # Deliberately used @, since requiredPrograms can return a list.
        @requiredPrograms{@progs} = 1;

        foreach my $prog (@progs) {
            $modulesRequiringProgram{$prog} //= { };
            $modulesRequiringProgram{$prog}->{$module->name()} = 1;
        }
    }

    my $wasError = 0;
    for my $prog (keys %requiredPrograms) {
        my %requiredPackages = (
            qmake => 'Qt',
            cmake => 'CMake',
            meson => 'Meson',
        );

        my $preferredPath = locate_exe($prog, @preferred_paths);
        my $programPath = $preferredPath || locate_exe($prog);

        # qmake is not necessarily named 'qmake'
        if (!$programPath && $prog eq 'qmake') {
            $programPath = ksb::BuildSystem::QMake::absPathToQMake();
        }

        if (!$programPath) {
            # Don't complain about Qt if we're building it...
            if ($prog eq 'qmake' && (
                    grep { $_->buildSystemType() eq 'Qt' ||
                           $_->buildSystemType() eq 'Qt5' } (@buildModules)) ||
                    pretending()
                )
            {
                next;
            }

            $wasError = 1;
            my $reqPackage = $requiredPackages{$prog} || $prog;

            my @modulesNeeding = keys %{$modulesRequiringProgram{$prog}};
            local $" = ', '; # List separator in output

            error (<<"EOF");

Unable to find r[b[$prog]. This program is absolutely essential for building
the modules: y[@modulesNeeding].

Please ensure the development packages for
$reqPackage are installed by using your distribution's package manager.
EOF
        }
    }

    return !$wasError;
}

# Function: _reachableModuleLogs
#
# Returns a list of module directory IDs that must be kept due to being
# referenced from the "latest" symlink.
#
# This function may call itself recursively if needed.
#
# Parameters:
# 1. The log directory under which to search for symlinks, including the "/latest"
#    part of the path.
sub _reachableModuleLogs
{
    my $logdir = shift;
    my @dirs;

    # A lexicalized var (my $foo) is required in face of recursiveness.
    opendir(my $fh, $logdir) or croak_runtime("Can't opendir $logdir: $!");
    my $dir = readdir($fh);

    while(defined $dir) {
        if (-l "$logdir/$dir") {
            my $link = readlink("$logdir/$dir");
            push @dirs, $link;
        }
        elsif ($dir !~ /^\.{1,2}$/) {
            # Skip . and .. directories (this is a great idea, trust me)
            push @dirs, _reachableModuleLogs("$logdir/$dir");
        }
        $dir = readdir $fh;
    }

    closedir $fh;

    # Extract numeric IDs from directory names.
    @dirs = map { m/(\d{4}-\d\d-\d\d-\d\d)/ } (@dirs);

    # Convert to unique list by abusing hash keys.
    my %tempHash;
    @tempHash{@dirs} = ();

    return keys %tempHash;
}

# Installs the given subroutine as a signal handler for a set of signals which
# could kill the program.
#
# First parameter is a reference to the sub to act as the handler.
sub _installSignalHandlers
{
    my $handlerRef = shift;
    my @signals = qw/HUP INT QUIT ABRT TERM PIPE/;

    @SIG{@signals} = ($handlerRef) x scalar @signals;
}

# Ensures that basic one-time setup to actually *use* installed software is
# performed, including .kdesrc-buildrc setup if necessary.
#
# Returns the appropriate exitcode to pass to the exit function
sub performInitialUserSetup
{
    my $self = shift;
    return ksb::FirstRun::setupUserSystem();
}

sub _holdPerformancePowerProfileIfPossible ($self)
{
    my $ctx = $self->context();

    my $dbusConnection;
    eval {
        info("Holding performance profile");

        return if pretending();

        # The hold will be automatically released once kdesrc-build exits
        ksb::DBus::requestPerformanceProfile()->then(sub ($stream) {
            $dbusConnection = $stream;
        });
    };

    return $dbusConnection;
}

# Accessors

sub context
{
    my $self = shift;
    return $self->{context};
}

sub metadataModule
{
    my $self = shift;
    return $self->{metadata_module};
}

sub runMode
{
    my $self = shift;
    return $self->{run_mode};
}

sub modules
{
    my $self = shift;
    return @{$self->{modules}};
}

sub workLoad
{
    my $self = shift;
    return $self->{workLoad};
}

1;
