package ksb::Application 0.20;

# Class: Application
#
# Contains the application-layer logic (i.e. creating a build context, reading
# options, parsing command-line, etc.)

use strict;
use warnings;
use 5.014;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

use ksb::Debug;
use ksb::Util;
use ksb::BuildContext 0.35;
use ksb::BuildSystem::QMake;
use ksb::BuildException 0.20;
use ksb::FirstRun;
use ksb::Module;
use ksb::ModuleResolver 0.20;
use ksb::ModuleSet 0.20;
use ksb::ModuleSet::KDEProjects;
use ksb::ModuleSet::Qt;
use ksb::OSSupport;
use ksb::RecursiveFH;
use ksb::DependencyResolver 0.20;
use ksb::DebugOrderHints;
use ksb::IPC::Pipe 0.20;
use ksb::IPC::Null;
use ksb::Updater::Git;
use ksb::Version qw(scriptVersion);

use List::Util qw(first min);
use File::Basename; # basename, dirname
use File::Glob ':glob';
use POSIX qw(:sys_wait_h _exit :errno_h);
use Getopt::Long qw(GetOptionsFromArray :config gnu_getopt nobundling);
use IO::Handle;
use IO::Select;

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

# Method: _readCommandLineOptionsAndSelectors
#
# Returns a list of module/module-set selectors, selected module/module-set
# options, and global options, based on the command-line arguments passed to
# this function.
#
# This is a package method, should be called as
# $app->_readCommandLineOptionsAndSelectors
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  cmdlineOptions - hashref to hold parsed modules options to be applied later.
#    *Note* this must be done separately, it is not handled by this subroutine.
#    Global options will be stored in a hashref at $cmdlineOptions->{global}.
#    Module or module-set options will be stored in a hashref at
#    $cmdlineOptions->{$moduleName} (it will be necessary to disambiguate
#    later in the run whether it is a module set or a single module).
#
#    If the global option 'start-program' is set, then the program to start and
#    its options will be found in a listref pointed to under the
#    'start-program' option.
#
#  selectors - listref to hold the list of module or module-set selectors to
#    build, in the order desired by the user. These will just be strings, the
#    caller will have to figure out whether the selector is a module or
#    module-set, and create any needed objects, and then set the recommended
#    options as listed in cmdlineOptions.
#
#  ctx - <BuildContext> to hold the global build state.
#
#  @options - The remainder of the arguments are treated as command line
#    arguments to process.
#
# Returns:
#  Nothing. An exception will be raised on failure, or this function may quit
#  the program directly (e.g. to handle --help, --usage).
sub _readCommandLineOptionsAndSelectors
{
    my $self = shift;
    my ($cmdlineOptionsRef, $selectorsRef, $ctx, @options) = @_;
    my $phases = $ctx->phases();
    my @savedOptions = @options; # Copied for use in debugging.
    my $os = ksb::OSSupport->new;
    my $version = "kdesrc-build " . scriptVersion();
    my $author = <<DONE;
$version was written (mostly) by:
  Michael Pyne <mpyne\@kde.org>

Many people have contributed code, bugfixes, and documentation.

Please report bugs using the KDE Bugzilla, at https://bugs.kde.org/
DONE

    # Getopt::Long will store options in %foundOptions, since that is what we
    # pass in. To allow for custom subroutines to handle an option it is
    # required that the sub *also* be in %foundOptions... whereupon it will
    # promptly be overwritten if we're not careful. Instead we let the custom
    # subs save to %auxOptions, and read those in back over it later.
    my (%foundOptions, %auxOptions);
    %foundOptions = (
        'show-info' => sub { say $version; say "OS: ", $os->vendorID(); exit },
        version => sub { say $version; exit },
        author  => sub { say $author;  exit },
        help    => sub { _showHelpMessage(); exit 0 },
        install => sub {
            $self->{run_mode} = 'install';
            $phases->phases('install');
        },
        uninstall => sub {
            $self->{run_mode} = 'uninstall';
            $phases->phases('uninstall');
        },
        'no-src' => sub {
            $phases->filterOutPhase('update');
        },
        'no-install' => sub {
            $phases->filterOutPhase('install');
        },
        'no-snapshots' => sub {
            # The documented form of disable-snapshots
            $auxOptions{'disable-snapshots'} = 1;
        },
        'no-tests' => sub {
            # The "right thing" to do
            $phases->filterOutPhase('test');

            # What actually works at this point.
            $foundOptions{'run-tests'} = 0;
        },
        'no-build' => sub {
            $phases->filterOutPhase('build');
        },
        # Mostly equivalent to the above
        'src-only' => sub {
            $phases->phases('update');

            # We have an auto-switching function that we only want to run
            # if --src-only was passed to the command line, so we still
            # need to set a flag for it.
            $foundOptions{'allow-auto-repo-move'} = 1;
        },
        'build-only' => sub {
            $phases->phases('build');
        },
        'install-only' => sub {
            $self->{run_mode} = 'install';
            $phases->phases('install');
        },
        prefix => sub {
            my ($optName, $arg) = @_;
            $auxOptions{prefix} = $arg;
            $foundOptions{kdedir} = $arg; #TODO: Still needed for compat?
            $foundOptions{reconfigure} = 1;
        },
        query => sub {
            my (undef, $arg) = @_;

            my $validMode = qr/^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/;
            die("Invalid query mode $arg")
                unless $arg =~ $validMode;

            # Add useful aliases
            $arg = 'source-dir'  if $arg =~ /^src-?dir$/;
            $arg = 'build-dir'   if $arg =~ /^build-?dir$/;
            $arg = 'install-dir' if $arg eq 'prefix';

            $self->{run_mode} = 'query';
            $auxOptions{query} = $arg;
            $auxOptions{pretend} = 1; # Implied pretend mode
        },
        pretend => sub {
            # Set pretend mode but also force the build process to run.
            $auxOptions{pretend} = 1;
            $foundOptions{'build-when-unchanged'} = 1;
        },
        resume => sub {
            $auxOptions{resume} = 1;
            $phases->filterOutPhase('update'); # Implied --no-src
            $foundOptions{'no-metadata'} = 1;  # Implied --no-metadata
        },
        verbose => sub { $foundOptions{'debug-level'} = ksb::Debug::WHISPER },
        quiet => sub { $foundOptions{'debug-level'} = ksb::Debug::NOTE },
        'really-quiet' => sub { $foundOptions{'debug-level'} = ksb::Debug::WARNING },
        debug => sub {
            $foundOptions{'debug-level'} = ksb::Debug::DEBUG;
            debug ("Commandline was: ", join(', ', @savedOptions));
        },

        # Hack to set module options
        'set-module-option-value' => sub {
            my ($optName, $arg) = @_;
            my ($module, $option, $value) = split (',', $arg, 3);
            if ($module && $option) {
                $cmdlineOptionsRef->{$module} //= { };
                $cmdlineOptionsRef->{$module}->{$option} = $value;
            }
        },

        # Getopt::Long doesn't set these up for us even though we specify an
        # array. Set them up ourselves.
        'start-program' => [ ],
        'ignore-modules' => [ ],

        # Module selectors, the <> is Getopt::Long shortcut for an
        # unrecognized non-option value (i.e. an actual argument)
        '<>' => sub {
            my $arg = shift;
            push @{$selectorsRef}, $arg;
        },
    );

    # Handle any "cmdline-eligible" options not already covered.
    my $flagHandler = sub {
        my ($optName, $optValue) = @_;

        # Assume to set if nothing provided.
        $optValue = 1 if (!defined $optValue or $optValue eq '');
        $optValue = 0 if lc($optValue) eq 'false';
        $optValue = 0 if !$optValue;

        $auxOptions{$optName} = $optValue;
    };

    foreach my $option (keys %ksb::BuildContext::defaultGlobalFlags) {
        if (!exists $foundOptions{$option}) {
            $foundOptions{$option} = $flagHandler; # A ref to a sub here!
        }
    }

    # Actually read the options.
    my $optsSuccess = GetOptionsFromArray(\@options, \%foundOptions,
        # Options here should not duplicate the flags and options defined below
        # from ksb::BuildContext!
        'version|v', 'author', 'help', 'show-info',
        'install', 'uninstall', 'no-src|no-svn', 'no-install', 'no-build',
        'no-tests', 'build-when-unchanged|force-build', 'no-metadata',
        'verbose', 'quiet|quite|q', 'really-quiet', 'debug',
        'reconfigure', 'colorful-output|color!', 'async!',
        'src-only|svn-only', 'build-only', 'install-only', 'build-system-only',
        'rc-file=s', 'prefix=s', 'niceness|nice:10', 'ignore-modules=s{,}',
        'print-modules', 'pretend|dry-run|p', 'refresh-build',
        'query=s', 'start-program|run=s{,}',
        'revision=i', 'resume-from=s', 'resume-after=s',
        'rebuild-failures', 'resume',
        'stop-after=s', 'stop-before=s', 'set-module-option-value=s',
        'metadata-only', 'list-build', 'dependency-tree',

        # Special sub used (see above), but have to tell Getopt::Long to look
        # for negatable boolean flags
        (map { "$_!" } (keys %ksb::BuildContext::defaultGlobalFlags)),

        # Default handling fine, still have to ask for strings.
        (map { "$_:s" } (keys %ksb::BuildContext::defaultGlobalOptions)),

        '<>', # Required to read non-option args
        );

    if (!$optsSuccess) {
        croak_runtime("Error reading command-line options.");
    }

    # To store the values we found, need to strip out the values that are
    # subroutines, as those are the ones we created. Alternately, place the
    # subs inline as an argument to the appropriate option in the
    # GetOptionsFromArray call above, but that's ugly too.
    my @readOptionNames = grep {
        ref($foundOptions{$_}) ne 'CODE'
    } (keys %foundOptions);

    # Slice assignment: $left{$key} = $right{$key} foreach $key (@keys), but
    # with hashref syntax everywhere.
    @{ $cmdlineOptionsRef->{'global'} }{@readOptionNames}
        = @foundOptions{@readOptionNames};

    @{ $cmdlineOptionsRef->{'global'} }{keys %auxOptions}
        = values %auxOptions;
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
    my $cmdlineOptions = { global => { }, };
    my $cmdlineGlobalOptions = $cmdlineOptions->{global};
    my $deferredOptions = { }; # 'options' blocks

    # Process --help, --install, etc. first.
    my @selectors;
    $self->_readCommandLineOptionsAndSelectors($cmdlineOptions, \@selectors,
        $ctx, @argv);

    # Convert list to hash for lookup
    my %ignoredSelectors =
        map { $_, 1 } @{$cmdlineGlobalOptions->{'ignore-modules'}};

    my @startProgramAndArgs = @{$cmdlineGlobalOptions->{'start-program'}};
    delete @{$cmdlineGlobalOptions}{qw/ignore-modules start-program/};

    # rc-file needs special handling.
    if (exists $cmdlineGlobalOptions->{'rc-file'} && $cmdlineGlobalOptions->{'rc-file'}) {
        $ctx->setRcFile($cmdlineGlobalOptions->{'rc-file'});
    }

    # disable async if only running a single phase.
    $cmdlineGlobalOptions->{async} = 0 if (scalar $ctx->phases()->phases() == 1);

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

    # _readConfigurationOptions will add pending global opts to ctx while ensuring
    # returned modules/sets have any such options stripped out. It will also add
    # module-specific options to any returned modules/sets.
    my @optionModulesAndSets = _readConfigurationOptions($ctx, $fh, $deferredOptions);
    close $fh;

    # Check if we're supposed to drop into an interactive shell instead.  If so,
    # here's the stop off point.

    if (@startProgramAndArgs) {
        $ctx->setupEnvironment(); # Read options from set-env
        $ctx->commitEnvironmentChanges(); # Apply env options to environment
        _executeCommandLineProgram(@startProgramAndArgs); # noreturn
    }

    # Everything else in cmdlineOptions should be OK to apply directly as a module
    # or context option.
    $ctx->setOption(%{$cmdlineGlobalOptions});

    # Selecting modules or module sets would requires having the KDE
    # build metadata (kde-build-metadata and sysadmin/repo-metadata)
    # available.
    $ctx->setKDEDependenciesMetadataModuleNeeded();
    $ctx->setKDEProjectsMetadataModuleNeeded();

    if (!exists $ENV{HARNESS_ACTIVE}) {
        # Running in a test harness, avoid downloading metadata which will be
        # ignored in the test or making changes to git config
        ksb::Updater::Git::verifyGitConfig($ctx);
        $self->_downloadKDEProjectMetadata();
    }

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

        if ($ctx->getOption('kde-languages')) {
            @modules = _expandl10nModules($ctx, @modules);
        }
    }

    # If modules were on the command line then they are effectively forced to
    # process unless overridden by command line options as well. If phases
    # *were* overridden on the command line, then no update pass is required
    # (all modules already have correct phases)
    @modules = _updateModulePhases(@modules) unless $commandLineModules;

    # TODO: Verify this does anything still
    my $metadataModule = $ctx->getKDEDependenciesMetadataModule();
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
            $ctx->getKDEDependenciesMetadataModule(),
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

# Returns a graph of Modules according to the kde-build-metadata dependency
# information.
#
# The kde-build-metadata repository must have already been updated, and the
# module factory must be setup. The modules for which to calculate the graph
# must be passed in as arguments
sub _resolveModuleDependencyGraph
{
    my $self = shift;
    my $ctx = $self->context();
    my $metadataModule = $ctx->getKDEDependenciesMetadataModule();
    my @modules = @_;

    my $graph = eval {
        my $dependencyResolver = ksb::DependencyResolver->new($self->{module_factory});
        my $branchGroup = $ctx->effectiveBranchGroup();

        for my $file ('dependency-data-common', "dependency-data-$branchGroup")
        {
            my $dependencyFile = $metadataModule->fullpath('source') . "/$file";
            my $dependencies = pretend_open($dependencyFile)
                or die "Unable to open $dependencyFile: $!";

            debug (" -- Reading dependencies from $dependencyFile");
            $dependencyResolver->readDependencyData($dependencies);
            close $dependencies;
        }

        return $dependencyResolver->resolveToModuleGraph(@modules);
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
        }
        else {
            for my $m (@modules) {
                say "$m: ", $query->($m);
            }
        }

        return 0;
    }

    my $result;

    if ($runMode eq 'build')
    {
        # No packages to install, we're in build mode

        # What we're going to do is fork another child to perform the source
        # updates while we build.  Setup for this first by initializing some
        # shared memory.
        my $ipc = 0;
        my $updateOptsSub = sub {
            my ($k, $v) = @_;
            $ctx->setPersistentOption($k, $v);
        };

        if ($ctx->getOption('async'))
        {
            $ipc = ksb::IPC::Pipe->new();
            $ipc->setPersistentOptionHandler($updateOptsSub);
        }

        if (!$ipc)
        {
            $ipc = ksb::IPC::Null->new();
            $ipc->setPersistentOptionHandler($updateOptsSub);

            whisper ("Using no IPC mechanism\n");

            note ("\n b[<<<  Update Process  >>>]\n");
            $result = _handle_updates ($ipc, $ctx);

            note (" b[<<<  Build Process  >>>]\n");
            $result = _handle_build ($ipc, $ctx) || $result;
        }
        else
        {
            $result = _handle_async_build ($ipc, $ctx);
            $ipc->outputPendingLoggedMessages() if debugging();
        }
    }
    elsif ($runMode eq 'install')
    {
        $result = _handle_install ($ctx);
    }
    elsif ($runMode eq 'uninstall')
    {
        $result = _handle_uninstall ($ctx);
    }

    _cleanup_log_directory($ctx) if $ctx->getOption('purge-old-logs');

    my $workLoad = $self->workLoad();
    my $dependencyGraph = $workLoad->{dependencyInfo}->{graph};
    _output_failed_module_lists($ctx, $dependencyGraph);


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

    my $color = 'g[b[';
    $color = 'r[b[' if $result;

    info ("${color}", $result ? ":-(" : ":-)") unless pretending();

    return $result;
}

# Method: finish
#
# Exits the script cleanly, including removing any lock files created.
#
# Parameters:
#  ctx - Required; BuildContext to use.
#  [exit] - Optional; if passed, is used as the exit code, otherwise 0 is used.
sub finish
{
    my $self = shift;
    my $ctx = $self->context();
    my $exitcode = shift // 0;

    if (pretending() || $self->{_base_pid} != $$) {
        # Abort early if pretending or if we're not the same process
        # that was started by the user (e.g. async mode, forked pipe-opens
        exit $exitcode;
    }

    $ctx->closeLock();
    $ctx->storePersistentOptions();

    my $logdir = $ctx->getLogDir();
    note ("Your logs are saved in y[$logdir]");

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
    my $optionRE = qr/\$\{([a-zA-Z0-9-]+)\}/;

    # The option is the first word, followed by the
    # flags on the rest of the line.  The interpretation
    # of the flags is dependent on the option.
    my ($option, $value) = ($input =~ /^\s*     # Find all spaces
                            ([-\w]+) # First match, alphanumeric, -, and _
                            # (?: ) means non-capturing group, so (.*) is $value
                            # So, skip spaces and pick up the rest of the line.
                            (?:\s+(.*))?$/x);

    $value = trimmed($value // '');

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
            warning (" *\n * WARNING: $sub_var_name is not set at line y[$.]\n *");   ## TODO: filename is missing
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
https://docs.kde.org/trunk5/en/extragear-utils/kdesrc-build/kde-modules-and-selection.html#module-sets
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
sub _parseModuleOptions
{
    my ($ctx, $fileReader, $module, $endRE) = @_;
    assert_isa($ctx, 'ksb::BuildContext');
    assert_isa($module, 'ksb::OptionsBase');

    my $endWord = $module->isa('ksb::BuildContext') ? 'global'     :
                  $module->isa('ksb::ModuleSet')    ? 'module-set' :
                  $module->isa('ksb::Module')       ? 'module'     :
                                                      'options';

    # Just look for an end marker if terminator not provided.
    $endRE //= qr/^end[\w\s]*$/;

    _markModuleSource($module, $fileReader->currentFilename() . ":$.");

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

        my ($option, $value) = _splitOptionAndValue($ctx, $_);

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
#  deferredOptions - An out parameter: a hashref holding the options set by any
#  'options' blocks read in by this function. Each key (identified by the name
#  of the 'options' block) will point to a hashref value holding the options to
#  apply.
#
# Returns:
#  @module - Heterogeneous list of <Modules> and <ModuleSets> defined in the
#  configuration file. No module sets will have been expanded out (either
#  kde-projects or standard sets).
#
# Throws:
#  - Config exceptions.
sub _readConfigurationOptions
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $fh = shift;
    my $deferredOptionsRef = shift;
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
        _parseModuleOptions($ctx, $fileReader, $ctx);

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
                ksb::ModuleSet->new($ctx, $modulename || "<module-set at line $.>"));
            $newModule->{'#create-id'} = ++$creation_order;

            # Save 'use-modules' entries so we can see if later module decls
            # are overriding/overlaying their options.
            my @moduleSetItems = $newModule->moduleNamesToFind();
            @seenModuleSetItems{@moduleSetItems} = ($newModule) x scalar @moduleSetItems;

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

            $deferredOptionsRef->{$modulename} = $options->{options};

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

# Function: _split_url
#
# Subroutine to split a url into a protocol and host
sub _split_url
{
    my $url = shift;
    my ($proto, $host) = ($url =~ m|([^:]*)://([^/]*)/|);

    return ($proto, $host);
}

# Function: _check_for_ssh_agent
#
# Checks if we are supposed to use ssh agent by examining the environment, and
# if so checks if ssh-agent has a list of identities.  If it doesn't, we run
# ssh-add (with no arguments) and inform the user.  This can be controlled with
# the disable-agent-check parameter.
#
# Parameters:
# 1. Build context
sub _check_for_ssh_agent
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');

    # Don't bother with all this if the user isn't even using SSH.
    return 1 if pretending();

    my @svnServers = grep {
        $_->scmType() eq 'svn'
    } ($ctx->modulesInPhase('update'));

    my @gitServers = grep {
        $_->scmType() eq 'git'
    } ($ctx->modulesInPhase('update'));

    my @sshServers = grep {
        my ($proto, $host) = _split_url($_->getOption('svn-server'));

        # Check if ssh is explicitly used in the proto, or if the host is the
        # developer main svn.
        (defined $proto && $proto =~ /ssh/) || (defined $host && $host =~ /^svn\.kde\.org/);
    } @svnServers;

    push @sshServers, grep {
        # Check for git+ssh:// or git@git.kde.org:/path/etc.
        my $repo = $_->getOption('repository');
        ($repo =~ /^git\+ssh:\/\//) || ($repo =~ /^[a-zA-Z0-9_.]+@.*:\//);
    } @gitServers;

    return 1 if (not @sshServers) or $ctx->getOption('disable-agent-check');
    whisper ("\tChecking for SSH Agent") if (scalar @sshServers);

    # We're using ssh to download, see if ssh-agent is running.
    return 1 unless exists $ENV{'SSH_AGENT_PID'};

    my $pid = $ENV{'SSH_AGENT_PID'};

    # It's supposed to be running, let's see if there exists the program with
    # that pid (this check is linux-specific at the moment).
    if (-d "/proc" and not -e "/proc/$pid")
    {
        warning ("r[ *] SSH Agent is enabled, but y[doesn't seem to be running].");
        warning ("Since SSH is used to download from Subversion you may want to see why");
        warning ("SSH Agent is not working, or correct the environment variable settings.");

        return 0;
    }

    # The agent is running, but does it have any keys?  We can't be more specific
    # with this check because we don't know what key is required.
    my $noKeys = 0;

    filter_program_output(sub { $noKeys ||= /no identities/ }, 'ssh-add', '-l');

    if ($noKeys)
    {
        # Use print so user can't inadvertently keep us quiet about this.
        print ksb::Debug::colorize (<<EOF);
b[y[*] SSH Agent does not appear to be managing any keys.  This will lead to you
  being prompted for every module update for your SSH passphrase.  So, we're
  running g[ssh-add] for you.  Please type your passphrase at the prompt when
  requested, (or simply Ctrl-C to abort the script).
EOF
        my @commandLine = ('ssh-add');
        my $identFile = $ctx->getOption('ssh-identity-file');
        push (@commandLine, $identFile) if $identFile;

        my $result = system (@commandLine);
        if ($result) # Run this code for both death-by-signal and nonzero return
        {
            my $rcfile = $ctx->rcFile();

            print "\nUnable to add SSH identity, aborting.\n";
            print "If you don't want kdesrc-build to check in the future,\n";
            print ksb::Debug::colorize ("Set the g[disable-agent-check] option to g[true] in your $rcfile.\n\n");

            return 0;
        }
    }

    return 1;
}

# Function: _handle_updates
#
# Subroutine to update a list of modules.
#
# Parameters:
# 1. IPC module to pass results to.
# 2. Build Context, which will be used to determine the module update list.
#
# The ipc parameter contains an object that is responsible for communicating
# the status of building the modules.  This function must account for every
# module in $ctx's update phase to the ipc object before returning.
#
# Returns 0 on success, non-zero on error.
sub _handle_updates
{
    my ($ipc, $ctx) = @_;
    my $kdesrc = $ctx->getSourceDir();
    my @update_list = $ctx->modulesInPhase('update');

    # No reason to print out the text if we're not doing anything.
    if (!@update_list)
    {
        $ipc->sendIPCMessage(ksb::IPC::ALL_UPDATING, "update-list-empty");
        $ipc->sendIPCMessage(ksb::IPC::ALL_DONE,     "update-list-empty");
        return 0;
    }

    if (not _check_for_ssh_agent($ctx))
    {
        $ipc->sendIPCMessage(ksb::IPC::ALL_FAILURE, "ssh-failure");
        return 1;
    }

    if (not -e $kdesrc)
    {
        whisper ("KDE source download directory doesn't exist, creating.\n");
        if (not super_mkdir ($kdesrc))
        {
            error ("Unable to make directory r[$kdesrc]!");
            $ipc->sendIPCMessage(ksb::IPC::ALL_FAILURE, "no-source-dir");

            return 1;
        }
    }

    # Once at this point, any errors we get should be limited to a module,
    # which means we can tell the build thread to start.
    $ipc->sendIPCMessage(ksb::IPC::ALL_UPDATING, "starting-updates");

    my $hadError = 0;
    foreach my $module (@update_list)
    {
        $ipc->setLoggedModule($module->name());

        # Note that this must be in this order to avoid accidentally not
        # running ->update() from short-circuiting if an error is noted.
        $hadError = !$module->update($ipc, $ctx) || $hadError;
    }

    $ipc->sendIPCMessage(ksb::IPC::ALL_DONE, "had_errors: $hadError");

    return $hadError;
}

# Builds the given module.
#
# Return value is the failure phase, or 0 on success.
sub _buildSingleModule
{
    my ($ipc, $ctx, $module, $startTimeRef) = @_;

    $ctx->resetEnvironment();
    $module->setupEnvironment();

    my $fail_count = $module->getPersistentOption('failure-count') // 0;
    my ($resultStatus, $message) = $ipc->waitForModule($module);
    $ipc->forgetModule($module);

    if ($resultStatus eq 'failed') {
        error ("\tUnable to update r[$module], build canceled.");
        $module->setPersistentOption('failure-count', ++$fail_count);
        return 'update';
    }
    elsif ($resultStatus eq 'success') {
        note ("\tSource update complete for g[$module]: $message");
    }
    # Skip actually building a module if the user has selected to skip
    # builds when the source code was not actually updated. But, don't skip
    # if we didn't successfully build last time.
    elsif ($resultStatus eq 'skipped' &&
        !$module->getOption('build-when-unchanged') &&
        $fail_count == 0)
    {
        note ("\tSkipping g[$module], its source code has not changed.");
        return 0;
    }
    elsif ($resultStatus eq 'skipped') {
        note ("\tNo changes to g[$module] source, proceeding to build.");
    }

    $$startTimeRef = time;
    $fail_count = $module->build() ? 0 : $fail_count + 1;
    $module->setPersistentOption('failure-count', $fail_count);

    return $fail_count > 0 ? 'build' : 0;
}

# Function: _handle_build
#
# Subroutine to handle the build process.
#
# Parameters:
# 1. IPC object to receive results from.
# 2. Build Context, which is used to determine list of modules to build.
#
# If the packages are not already checked-out and/or updated, this
# subroutine WILL NOT do so for you.
#
# This subroutine assumes that the source directory has already been set up.
# It will create the build directory if it doesn't already exist.
#
# If $builddir/$module/.refresh-me exists, the subroutine will
# completely rebuild the module (as if --refresh-build were passed for that
# module).
#
# Returns 0 for success, non-zero for failure.
sub _handle_build
{
    my ($ipc, $ctx) = @_;
    my @build_done;
    my @modules = $ctx->modulesInPhase('build');
    my $result = 0;

    # No reason to print building messages if we're not building.
    return 0 if scalar @modules == 0;

    # Check for absolutely essential programs now.
    if (!_checkForEssentialBuildPrograms($ctx) &&
        !exists $ENV{KDESRC_BUILD_IGNORE_MISSING_PROGRAMS})
    {
        error (" r[b[*] Aborting now to save a lot of wasted time.");
        error (" y[b[*] export KDESRC_BUILD_IGNORE_MISSING_PROGRAMS=1 and re-run (perhaps with --no-src)");
        error (" r[b[*] to continue anyways. If this check was in error please report a bug against");
        error (" y[b[*] kdesrc-build at https://bugs.kde.org/");

        return 1;
    }

    # IPC queue should have a message saying whether or not to bother with the
    # build.
    $ipc->waitForStreamStart();

    $ctx->unsetPersistentOption('global', 'resume-list');

    my $outfile = pretending() ? '/dev/null'
                               : $ctx->getLogDir() . '/build-status';

    open (STATUS_FILE, '>', $outfile) or do {
        error (<<EOF);
	Unable to open output status file r[b[$outfile]
	You won't be able to use the g[--resume] switch next run.\n";
EOF
        $outfile = undef;
    };

    my $num_modules = scalar @modules;
    my $statusViewer = $ctx->statusViewer();
    my $i = 1;

    $statusViewer->numberModulesTotal(scalar @modules);

    while (my $module = shift @modules)
    {
        my $moduleName = $module->name();
        my $moduleSet = $module->moduleSet()->name();
        my $modOutput = $moduleName;

        if (debugging(ksb::Debug::WHISPER)) {
            $modOutput .= " (build system " . $module->buildSystemType() . ")"
        }

        $moduleSet = " from g[$moduleSet]" if $moduleSet;
        note ("Building g[$modOutput]$moduleSet ($i/$num_modules)");

        my $start_time = time;
        my $failedPhase = _buildSingleModule($ipc, $ctx, $module, \$start_time);
        my $elapsed = prettify_seconds(time - $start_time);

        if ($failedPhase)
        {
            # FAILURE
            $ctx->markModulePhaseFailed($failedPhase, $module);
            print STATUS_FILE "$module: Failed on $failedPhase after $elapsed.\n";

            if ($result == 0) {
                # No failures yet, mark this as resume point
                my $moduleList = join(', ', map { "$_" } ($module, @modules));
                $ctx->setPersistentOption('global', 'resume-list', $moduleList);
            }
            $result = 1;

            if ($module->getOption('stop-on-failure'))
            {
                note ("\n$module didn't build, stopping here.");
                return 1; # Error
            }

            $statusViewer->numberModulesFailed(1 + $statusViewer->numberModulesFailed);
        }
        else {
            # Success
            print STATUS_FILE "$module: Succeeded after $elapsed.\n";

            push @build_done, $moduleName; # Make it show up as a success

            $statusViewer->numberModulesSucceeded(1 + $statusViewer->numberModulesSucceeded);
        }

        $i++;
    }
    continue # Happens at the end of each loop and on next
    {
        print "\n"; # Space things out
    }

    if ($outfile)
    {
        close STATUS_FILE;

        # Update the symlink in latest to point to this file.
        my $logdir = $ctx->getSubdirPath('log-dir');
        if (-l "$logdir/latest/build-status") {
            safe_unlink("$logdir/latest/build-status");
        }
        symlink($outfile, "$logdir/latest/build-status");
    }

    info ("<<<  g[PACKAGES SUCCESSFULLY BUILT]  >>>") if scalar @build_done > 0;

    my $successes = scalar @build_done;
    # TODO: l10n
    my $mods = $successes == 1 ? 'module' : 'modules';

    if (not pretending())
    {
        # Print out results, and output to a file
        my $kdesrc = $ctx->getSourceDir();
        open BUILT_LIST, ">$kdesrc/successfully-built";
        foreach my $module (@build_done)
        {
            info ("$module") if $successes <= 10;
            print BUILT_LIST "$module\n";
        }
        close BUILT_LIST;

        info ("Built g[$successes] $mods") if $successes > 10;
    }
    else
    {
        # Just print out the results
        if ($successes <= 10) {
            info ('g[', join ("]\ng[", @build_done), ']');
        }
        else {
            info ("Built g[$successes] $mods") if $successes > 10;
        }
    }

    info (' '); # Space out nicely

    return $result;
}

# Function: _handle_async_build
#
# This subroutine special-cases the handling of the update and build phases, by
# performing them concurrently (where possible), using forked processes.
#
# Only one thread or process of execution will return from this procedure. Any
# other processes will be forced to exit after running their assigned module
# phase(s).
#
# We also redirect ksb::Debug output messages to be sent to a single process
# for display on the terminal instead of allowing them all to interrupt each
# other.
#
# Parameters:
# 1. IPC Object to use for sending/receiving update/build status. It must be
# an object type that supports IPC concurrency (e.g. IPC::Pipe).
# 2. Build Context to use, from which the module lists will be determined.
#
# Returns 0 on success, non-zero on failure.
sub _handle_async_build
{
    # The exact method for async is that two children are forked.  One child
    # is a source update process.  The other child is a monitor process which will
    # hold status updates from the update process so that the updates may
    # happen without waiting for us to be ready to read.

    my ($ipc, $ctx) = @_;

    print "\n"; # Space out from metadata messages.

    my $result = 0;
    my $monitorPid = fork;
    if ($monitorPid == 0) {
        # child
        my $updaterToMonitorIPC = ksb::IPC::Pipe->new();
        my $updaterPid = fork;

        $SIG{INT} = sub { POSIX::_exit(EINTR); };

        if ($updaterPid) {
            $0 = 'kdesrc-build-updater';
            $updaterToMonitorIPC->setSender();
            ksb::Debug::setIPC($updaterToMonitorIPC);

            POSIX::_exit (_handle_updates ($updaterToMonitorIPC, $ctx));
        }
        else {
            $0 = 'kdesrc-build-monitor';
            $ipc->setSender();
            $updaterToMonitorIPC->setReceiver();

            $ipc->setLoggedModule('#monitor#'); # This /should/ never be used...
            ksb::Debug::setIPC($ipc);

            POSIX::_exit (_handle_monitoring ($ipc, $updaterToMonitorIPC));
        }
    }
    else {
        # Still the parent, let's do the build.
        $ipc->setReceiver();
        $result = _handle_build ($ipc, $ctx);
    }

    $ipc->waitForEnd();
    $ipc->close();

    # Display a message for updated modules not listed because they were not
    # built.
    my $unseenModulesRef = $ipc->unacknowledgedModules();
    if (%$unseenModulesRef) {
        note ("The following modules were updated but not built:");
        foreach my $modulename (keys %$unseenModulesRef) {
            note ("\t$modulename");
        }
    }

    # It's possible if build fails on first module that git or svn is still
    # running. Make them stop too.
    if (waitpid ($monitorPid, WNOHANG) == 0) {
        kill 'INT', $monitorPid;

        # Exit code is in $?.
        waitpid ($monitorPid, 0);
        $result = 1 if $? != 0;
    }

    return $result;
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

# Function: _handle_monitoring
#
# This is the main subroutine for the monitoring process when using IPC::Pipe.
# It reads in all status reports from the source update process and then holds
# on to them.  When the build process is ready to read information we send what
# we have.  Otherwise we're waiting on the update process to send us something.
#
# This convoluted arrangement is required to allow the source update
# process to go from start to finish without undue interruption on it waiting
# to write out its status to the build process (which is usually busy).
#
# Parameters:
# 1. the IPC object to use to send to build process.
# 2. the IPC object to use to receive from update process.
#
# Returns 0 on success, non-zero on failure.
sub _handle_monitoring
{
    my ($ipcToBuild, $ipcFromUpdater) = @_;

    my @msgs;  # Message queue.

    # We will write to the build process and read from the update process.

    my $sendFH = $ipcToBuild->{fh}     || croak_runtime('??? missing pipe to build proc');
    my $recvFH = $ipcFromUpdater->{fh} || croak_runtime('??? missing pipe from monitor');

    my $readSelector  = IO::Select->new($recvFH);
    my $writeSelector = IO::Select->new($sendFH);

    # Start the loop.  We will be waiting on either read or write ends.
    # Whenever select() returns we must check both sets.
    while (
        my ($readReadyRef, $writeReadyRef) =
            IO::Select->select($readSelector, $writeSelector, undef))
    {
        if (!$readReadyRef && !$writeReadyRef) {
            # Some kind of error occurred.
            return 1;
        }

        # Check for source updates first.
        if (@{$readReadyRef})
        {
            undef $@;
            my $msg = eval { $ipcFromUpdater->receiveMessage(); };

            # undef msg indicates EOF, so check for exception obj specifically
            die $@ if $@;

            # undef can be returned on EOF as well as error.  EOF means the
            # other side is presumably done.
            if (! defined $msg)
            {
                $readSelector->remove($recvFH);
                last; # Select no longer needed, just output to build.
            }
            else
            {
                push @msgs, $msg;

                # We may not have been waiting for write handle to be ready if
                # we were blocking on an update from updater thread.
                $writeSelector->add($sendFH) unless $writeSelector->exists($sendFH);
            }
        }

        # Now check for build updates.
        if (@{$writeReadyRef})
        {
            # If we're here the update is still going.  If we have no messages
            # to send wait for that first.
            if (not @msgs)
            {
                $writeSelector->remove($sendFH);
            }
            else
            {
                # Send the message (if we got one).
                if (!$ipcToBuild->sendMessage(shift @msgs))
                {
                    error ("r[mon]: Build process stopped too soon! r[$!]");
                    return 1;
                }
            }
        }
    }

    # Send all remaining messages.
    while (@msgs)
    {
        if (!$ipcToBuild->sendMessage(shift @msgs))
        {
            error ("r[mon]: Build process stopped too soon! r[$!]");
            return 1;
        }
    }

    $ipcToBuild->close();

    return 0;
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

# This function converts any 'l10n' references on the command line to return a l10n
# module with the proper build system, scm type, etc.
#
# The languages are selected using global/kde-languages (which should be used
# exclusively from the configuration file).
sub _expandl10nModules
{
    my ($ctx, @modules) = @_;
    my $l10n = 'l10n-kde4';

    assert_isa($ctx, 'ksb::BuildContext');

    # Only filter if 'l10n' is actually present in list.
    my @matches = grep {$_->name() =~ /^(?:$l10n|l10n)$/} @modules;
    my @langs = split(' ', $ctx->getOption('kde-languages'));

    return @modules if (!@matches || !@langs);

    my $l10nModule;
    for my $match (@matches)
    {
        # Remove all instances of l10n.
        @modules = grep {$_->name() ne $match->name()} @modules;

        # Save l10n module if user had it in config. We only save the first
        # one encountered though.
        $l10nModule //= $match;
    }

    # No l10n module? Just create one.
    $l10nModule //= ksb::Module->new($ctx, $l10n);

    whisper ("\tAdding languages ", join(';', @langs), " to build.");

    $l10nModule->setScmType('l10n');
    my $scm = $l10nModule->scm();

    # Add all required directories to the l10n module. Its buildsystem should
    # know to skip scripts and templates.
    $scm->setLanguageDirs(qw/scripts templates/, @langs);
    $l10nModule->setBuildSystem($scm);

    push @modules, $l10nModule;
    return @modules;
}

# Updates the built-in phase list for all Modules passed into this function in
# accordance with the options set by the user.
sub _updateModulePhases
{
    whisper ("Filtering out module phases.");
    for my $module (@_) {
        if ($module->getOption('manual-update') ||
            $module->getOption('no-svn') || $module->getOption('no-src'))
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

# This subroutine extract the value from options of the form --option=value,
# which can also be expressed as --option value.
#
# The first parameter is the option that the user passed to the cmd line (e.g.
# --prefix=/opt/foo).
# The second parameter is a reference to the list of command line options.
#
# The return value is the value of the option (the list of options might be
# shorter by 1, copy it if you don't want it to change), or undef if no value
# was provided.
sub _extractOptionValue
{
    my ($option, $options_ref) = @_;

    if ($option =~ /=/)
    {
        my @value = split(/=/, $option);
        shift @value; # We don't need the first one, that the --option part.

        return if (scalar @value == 0);

        # If we have more than one element left in @value it's because the
        # option itself has an = in it, make sure it goes back in the answer.
        return join('=', @value);
    }

    return if scalar @{$options_ref} == 0;
    return shift @{$options_ref};
}

# Like _extractOptionValue, but throws an exception if the value is not
# actually present, so you don't have to check for it yourself. If you do get a
# return value, it will be defined to something.
sub _extractOptionValueRequired
{
    my ($option, $options_ref) = @_;
    my $returnValue = _extractOptionValue($option, $options_ref);

    if (not defined $returnValue) {
        croak_runtime("Option $option needs to be set to some value instead of left blank");
    }

    return $returnValue;
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
    my @needed = _reachableModuleLogs("$logdir/latest");

    # Convert a list to a hash lookup since Perl lacks a "list-has"
    my %needed_table;
    @needed_table{@needed} = (1) x @needed;

    my $length = scalar @dirs - scalar @needed;
    if ($length > 15) { # Arbitrary man is arbitrary
        note ("Removing y[b[$length] out of g[b[$#dirs] old log directories (this may take some time)...");
    }
    elsif ($length > 0) {
        info ("Removing g[b[$length] out of g[b[$#dirs] old log directories...");
    }

    for my $dir (@dirs) {
        my ($id) = ($dir =~ m/(\d\d\d\d-\d\d-\d\d-\d\d)/);
        safe_rmtree($dir) unless $needed_table{$id};
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

    if (@fail_list)
    {
        debug ("Message is $message");
        debug ("\tfor ", join(', ', @fail_list));
    }

    if (scalar @fail_list > 0)
    {
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
            $logfile =~ s|$homedir|~|;

            warning ("r[$module]") if pretending();
            warning ("r[$module] - g[$logfile]") if not pretending();
        }
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

    if (@super_fail)
    {
        warning ("\nThe following modules have failed to build 3 or more times in a row:");
        warning ("\tr[b[$_]") foreach @super_fail;
        warning ("\nThere is probably a local error causing this kind of consistent failure, it");
        warning ("is recommended to verify no issues on the system.\n");
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
sub _installCustomFile
{
    use File::Copy qw(copy);

    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my ($sourceFilePath, $destFilePath, $md5KeyName) = @_;
    my $baseName = basename($sourceFilePath);

    if (-e $destFilePath) {
        my $existingMD5 = $ctx->getPersistentOption('/digests', $md5KeyName) // '';

        if (fileDigestMD5($destFilePath) ne $existingMD5) {
            if (!$ctx->getOption('#delete-my-settings')) {
                error ("\tr[*] Installing \"b[$baseName]\" would overwrite an existing file:");
                error ("\tr[*]  y[b[$destFilePath]");
                error ("\tr[*] If this is acceptable, please delete the existing file and re-run,");
                error ("\tr[*] or pass b[--delete-my-settings] and re-run.");

                return;
            }
            elsif (!pretending()) {
                copy ($destFilePath, "$destFilePath.kdesrc-build-backup");
            }
        }
    }

    if (!pretending()) {
        _installTemplatedFile($sourceFilePath, $destFilePath, $ctx);
        $ctx->setPersistentOption('/digests', $md5KeyName, fileDigestMD5($destFilePath));
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
        map { "$_/sample-kde-env-master.sh" } @searchPaths
    );
    my $sessionScript = first { -f $_ } (
        map { "$_/sample-xsession.sh" } @searchPaths
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

        my $preferredPath = absPathToExecutable($prog, @preferred_paths);
        my $programPath = $preferredPath || absPathToExecutable($prog);

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
            local $, = ', '; # List separator in output

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

# Shows a help message and version. Does not exit.
sub _showHelpMessage
{
    my $scriptVersion = scriptVersion();
    say <<DONE;
kdesrc-build $scriptVersion
Copyright (c) 2003 - 2020 Michael Pyne <mpyne\@kde.org> and others, and is
distributed under the terms of the GNU GPL v2.

This script automates the download, build, and install process for KDE software
using the latest available source code.

Configuration is controlled from "\$PWD/kdesrc-buildrc" or "~/.kdesrc-buildrc".
See kdesrc-buildrc-sample for an example.

Usage: \$ $0 [--options] [module names]
    All configured modules are built if none are listed.

Important Options:
    --pretend              Don't actually take major actions, instead describe
                           what would be done.
    --list-build           List what modules would be built in the order in
                           which they would be built.
    --dependency-tree      Print out dependency information on the modules that
                           would be built, using a `tree` format. Very useful
                           for learning how modules relate to each other. May
                           generate a lot of output.
    --no-src               Don't update source code, just build/install.
    --src-only             Only update the source code
    --refresh-build        Start the build from scratch.

    --rc-file=<filename>   Read configuration from filename instead of default.
    --initial-setup        Installs Plasma env vars (~/.bashrc), required
                           system pkgs, and a base kdesrc-buildrc.

    --resume-from=<pkg>    Skips modules until just before or after the given
    --resume-after=<pkg>       package, then operates as normal.
    --stop-before=<pkg>    Stops just before or after the given package is
    --stop-after=<pkg>         reached.

    --include-dependencies Also builds KDE-based dependencies of given modules.
      (This is enabled by default; use --no-include-dependencies to disable)
    --stop-on-failure      Stops the build as soon as a package fails to build.

More docs at https://docs.kde.org/trunk5/en/extragear-utils/kdesrc-build/
    Supported configuration options: https://go.kde.org/u/ksboptions
    Supported cmdline options:       https://go.kde.org/u/ksbcmdline
DONE

    # Look for indications this is the first run.
    if (! -e "./kdesrc-buildrc" && ! -e "$ENV{HOME}/.kdesrc-buildrc") {
        say <<DONE;
  **  **  **  **  **
It looks like kdesrc-build has not yet been setup. For easy setup, run:
    $0 --initial-setup

This will adjust your ~/.bashrc to find installed software, run your system's
package manager to install required dependencies, and setup a kdesrc-buildrc
that can be edited from there.
DONE
    }
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
