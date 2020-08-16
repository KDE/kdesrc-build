package ksb::Application 0.20;

# Class: Application
#
# Contains the application-layer logic (i.e. creating a build context, reading
# options, parsing command-line, etc.)

use strict;
use warnings;
use 5.014;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

use ksb::Debug 0.30;
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
use ksb::PromiseChain;
use ksb::RecursiveFH;
use ksb::Debug;
use ksb::DebugOrderHints;
use ksb::DependencyResolver 0.20;
use ksb::Updater::Git;
use ksb::Version qw(scriptVersion);

use Mojo::IOLoop;
use Mojo::Promise;

use Fcntl; # For sysopen
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

    # TODO: Do something with @options

    my $self = bless {
        context         => ksb::BuildContext->new(),
        metadata_module => undef,
        run_mode        => 'build',
        modules         => undef,
        module_resolver => undef, # ksb::ModuleResolver but see below
        _base_pid       => $$, # See finish()
    }, $class;

    # Default to colorized output if sending to TTY
    ksb::Debug::setColorfulOutput(-t STDOUT);

    return $self;
}

# This is a convenience function to run a ksb::Application that is fully
# setup (in terms of workload object, modules set to process, etc.) based
# on the passed arguments as if they were command line arguments.
#
# Call as a package method, like:
#   $app = ksb::Application::newFromCmdline(@args);
#
# Returns:
#   a ksb::Application
sub newFromCmdline
{
    my @args = @_;

    my $app = ksb::Application->new();
    my $optsAndSelectors = readCommandLineOptionsAndSelectors(@args);
    my @selectors        = $app->establishContext($optsAndSelectors);

    $app->setModulesToProcess($app->modulesFromSelectors(@selectors));

    return $app;
}

# Call after establishContext (to read in config file and do one-time metadata
# reading), but before you call startHeadlessBuild.
#
# Parameter:
#
# - workload, a hashref containing the following entries:
# {
#   selectedModules: listref with the selected ksb::Modules to build
#   dependencyInfo: reference to a dependency info object created by
#     ksb::DependencyResolver
#   build: a boolean indicating whether to go through with build or not
# }
sub setModulesToProcess
{
    my ($self, $workLoad) = @_;
    croak_internal("Expecting workload object!")
        unless ref $workLoad eq 'HASH';

    $self->{modules}  = $workLoad->{selectedModules};
    $self->{workLoad} = $workLoad;

    $self->context()->addModule($_)
        foreach @{$self->{modules}};

    # i.e. niceness, ulimits, etc.
    $self->context()->setupOperatingEnvironment();
}

# Sets the application to be non-interactive, intended to make this suitable as
# a backend for a Mojolicious-based web server with a separate U/I.
sub setHeadless
{
    my $self = shift;
    $self->{run_mode} = 'headless';
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
#  @options - The remainder of the arguments are treated as command line
#    arguments to process.
#
# Returns:
#  A hashref of the form:
#    {
#      options => {
#        # cmdline options
#        global => {
#          'no-src' => 1,
#          foo      => 'bar',
#        },
#        # per-module *OR* module-set options passed on cmdline
#        module_name => {
#          foo     => 'baz',
#        },
#      },
#      # always present, possibly empty. If empty the user did not request any
#      # specific modules and all should be built. If present, is in the order
#      # requested by the user
#      selectors => [ 'selector-1', 'selector-2', etc. ],
#      start-program => ['foo', @args], # only present if a program should be run
#      ignore-modules => ['mod1', 'mod2'] # selectors to ignore from --ignore-modules
#    }
#
#  The options and selectors returned are not applied directly to any module or context.
#
#  An exception will be raised on failure, or this function may quit
#  the program directly (e.g. to handle --help, --usage).
sub readCommandLineOptionsAndSelectors
{
    my @options = @_;

    my $result = {
        options   => { },
        selectors => [ ],
    };

    my $cmdlineOptionsRef = $result->{options};
    my $selectorsRef      = $result->{selectors};

    # Getopt::Long will store options in %foundOptions, since that is what we
    # pass in. To allow for custom subroutines to handle an option it is
    # required that the sub *also* be in %foundOptions... whereupon it will
    # promptly be overwritten if we're not careful. Instead we let the custom
    # subs save to %auxOptions, and read those in back over it later.
    my (%foundOptions, %auxOptions);
    %foundOptions = (
        'no-snapshots' => sub {
            # The documented form of disable-snapshots
            $auxOptions{'disable-snapshots'} = 1;
        },
        'no-tests' => sub {
            # What actually works at this point. Filtering phases is the right thing to
            # do though, see its usage in _updateBuildContextFromOptions
            $foundOptions{'run-tests'} = 0;
        },
        # Mostly equivalent to the above
        'src-only' => sub {
            # We have an auto-switching function that we only want to run
            # if --src-only was passed to the command line, so we still
            # need to set a flag for it.
            $foundOptions{'allow-auto-repo-move'} = 1;
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

            die("Cannot combine multiple query modes")
                if exists $auxOptions{query};

            # Add useful aliases
            $arg = 'source-dir'  if $arg =~ /^src-?dir$/;
            $arg = 'build-dir'   if $arg =~ /^build-?dir$/;
            $arg = 'install-dir' if $arg eq 'prefix';

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
            $foundOptions{'no-metadata'} = 1;  # Implied --no-metadata
        },
        verbose        => sub { $foundOptions{'debug-level'} = ksb::Debug::WHISPER },
        quiet          => sub { $foundOptions{'debug-level'} = ksb::Debug::NOTE },
        'really-quiet' => sub { $foundOptions{'debug-level'} = ksb::Debug::WARNING },
        debug => sub {
            $foundOptions{'debug-level'} = ksb::Debug::DEBUG;
            debug ("Commandline was: ", join(', ', @options));
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
        'start-program'  => [ ],
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
        'install|install-only', 'uninstall', 'no-src|no-svn', 'no-install', 'no-build',
        'no-tests', 'build-when-unchanged|force-build', 'no-metadata',
        'verbose', 'quiet|quite|q', 'really-quiet', 'debug',
        'reconfigure', 'colorful-output|color!',
        'src-only|svn-only', 'build-only', 'build-system-only',
        'rc-file=s', 'prefix=s', 'niceness|nice:10', 'ignore-modules=s{,}',
        'pretend|dry-run|p', 'refresh-build',
        'query=s', 'start-program|run=s{,}',
        'launch-browser',
        'revision=i', 'resume-from=s', 'resume-after=s',
        'rebuild-failures', 'resume',
        'stop-after=s', 'stop-before=s', 'set-module-option-value=s',
        'metadata-only',

        # Debug-only flags
        'print-modules', 'list-build', 'dependency-tree',

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

    return $result;
}

# Method: _handleEarlyOptions
#
# Uses the user-requested options (as returned by
# readCommandLineOptionsAndSelectors) and handles any options that should be
# handled without launching the backend and which would cause the script to
# exit, such as --help and --query.
#
# This function may exit entirely for some options, and since the rc-file has
# not been read yet, does not handle all possible cases where an early exit is
# required.
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  optsAndSelectors - As from readCommandLineOptionsAndSelectors
#
# Returns:
#  There is no return value. The function may not return at all, and exit instead.
sub _handleEarlyOptions
{
    my $optsAndSelectors = shift;

    croak_internal("No options and selectors passed")
        unless $optsAndSelectors;

    my $version = "kdesrc-build " . scriptVersion();
    my $author = <<DONE;
$version was written (mostly) by:
  Michael Pyne <mpyne\@kde.org>

Many people have contributed code, bugfixes, and documentation.

Please report bugs using the KDE Bugzilla, at https://bugs.kde.org/
DONE

    my %optionHandlers = (
        'show-info' => sub { say "$version\nOS: ", ksb::OSSupport->new->vendorID(); },
        version     => sub { say $version },
        author      => sub { say $author  },
        help        => sub { _showHelpMessage() },
    );

    my $globalOpts = $optsAndSelectors->{options}->{global};
    foreach my $early_opt (keys %optionHandlers) {
        if (exists $globalOpts->{$early_opt}) {
            $optionHandlers{$early_opt}->();
            exit;
        }
    }
}

# Method: _updateBuildContextFromOptions
#
# Uses the user-requested options (as returned by
# readCommandLineOptionsAndSelectors) to update the build context and
# self-options as appropriate, including functions such as updating the
# run-mode. Options that might cause early exit are not handled, see
# _handleEarlyOptions for those.
#
# Since the rc-file has not been read yet, this does not handle all possible
# cases where an early exit is required.
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  ctx - <BuildContext> to hold the global build state.
#  optsAndSelectors - As from readCommandLineOptionsAndSelectors
#
# Returns:
#  There is no return value.
sub _updateBuildContextFromOptions
{
    my ($self, $ctx, $optsAndSelectors) = @_;

    my $phases = $ctx->phases();

    my %optionHandlers = (
        'no-src' => sub {
            $phases->filterOutPhase('update');
        },
        'no-install' => sub {
            $phases->filterOutPhase('install');
        },
        'no-tests' => sub {
            # The "right thing" to do... doesn't fully work yet, so see also the 'run-tests' option
            $phases->filterOutPhase('test');
        },
        'no-build' => sub {
            $phases->filterOutPhase('build');
        },
        install => sub {
            $phases->phases('install');
        },
        uninstall => sub {
            $phases->phases('uninstall');
        },
        # Mostly equivalent to the above
        'src-only' => sub {
            $phases->phases('update');
        },
        'build-only' => sub {
            $phases->phases('build');
        },
        resume => sub {
            $phases->filterOutPhase('update'); # Implied --no-src
        },
    );

    while (my ($opt, $value) = each %{$optsAndSelectors->{options}->{global}}) {
        $optionHandlers{$opt}->($value) if exists $optionHandlers{$opt};
    }
}

# Generates the build context, builds various module, dependency and branch
# group resolvers, and splits up the provided option/selector mix read from
# cmdline into selectors (returned to caller, if any) and pre-built context and
# resolvers.
#
# Use "modulesFromSelectors" to further generate the list of ksb::Modules in
# dependency order.
#
# After this function is called all module set selectors will have been
# expanded, and we will have downloaded kde-projects metadata.
#
# Returns: List of Selectors to build.
sub establishContext
{
    my ($self, $optsAndSelectors) = @_;

    # Note: Don't change the order around unless you're sure of what you're
    # doing.

    my $ctx = $self->context();

    # Process --help, --install, etc. first.
    $self->_updateBuildContextFromOptions($ctx, $optsAndSelectors); # may exit process

    my @selectors = @{$optsAndSelectors->{selectors}};
    my $cmdlineOptions = $optsAndSelectors->{options};
    my $cmdlineGlobalOptions = $cmdlineOptions->{global};
    my $deferredOptions = { }; # 'options' blocks

    # Convert list to hash for lookup
    my %ignoredSelectors =
        map { $_, 1 } @{$cmdlineGlobalOptions->{'ignore-modules'}};

    # Set aside debug-related and other short-circuit cmdline options
    # for kdesrc-build CLI driver to handle
    my @debugFlags = qw(dependency-tree list-build print-modules);
    $self->{debugFlags} = {
        map { ($_, 1) }
            grep { defined $cmdlineGlobalOptions->{$_} }
                (@debugFlags)
    };

    my @startProgramAndArgs = @{$cmdlineGlobalOptions->{'start-program'}};
    delete @{$cmdlineGlobalOptions}{qw/ignore-modules start-program/};

    # rc-file needs special handling.
    if (exists $cmdlineGlobalOptions->{'rc-file'} && $cmdlineGlobalOptions->{'rc-file'}) {
        $ctx->setRcFile($cmdlineGlobalOptions->{'rc-file'});
    }

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

    if (!exists $ENV{HARNESS_ACTIVE} && !$self->{run_mode} eq 'headless') {
        # In some modes (testing, acting as headless backend), we should avoid
        # downloading metadata automatically, so don't.
        ksb::Updater::Git::verifyGitConfig($ctx);
        $self->_downloadKDEProjectMetadata();
    }

    # At this point we have our list of candidate modules / module-sets (as read in
    # from rc-file). The module sets have not been expanded into modules.
    # We also might have cmdline "selectors" to determine which modules or
    # module-sets to choose. First let's select module sets, and expand them.

    my $moduleResolver
        = $self->{module_resolver}
        = ksb::ModuleResolver->new($ctx);
    $moduleResolver->setCmdlineOptions($cmdlineOptions);
    $moduleResolver->setDeferredOptions($deferredOptions);
    $moduleResolver->setInputModulesAndOptions(\@optionModulesAndSets);
    $moduleResolver->setIgnoredSelectors([keys %ignoredSelectors]);

    # The user might only want metadata to update to allow for a later
    # --pretend run, check for that here.
    if (exists $cmdlineGlobalOptions->{'metadata-only'}) {
        return;
    }

    return @selectors;
}

# Requires establishContext to have been called first. Converts string-based
# "selectors" for modules or module-sets into a list of ksb::Modules (only
# modules, no sets), and returns associated metadata including dependencies.
#
# After this function is called all module set selectors will have been
# expanded, and we will have downloaded kde-projects metadata.
#
# The modules returned must still be added (using setModulesToProcess) to the
# context if you intend to build. This is a separate step to allow for some
# introspection prior to making choice to build.
#
# Returns: A hashref to a workload object (as described in setModulesToProcess)
sub modulesFromSelectors
{
    my ($self, @selectors) = @_;
    my $moduleResolver = $self->{module_resolver};
    my $ctx = $self->context();

    my @modules;
    if (@selectors) {
        @modules = $moduleResolver->resolveSelectorsIntoModules(@selectors);
    }
    else {
        # Build everything in the rc-file, in the order specified.
        my @rcfileModules = @{$moduleResolver->{inputModulesAndOptions}};
        @modules = $moduleResolver->expandModuleSets(@rcfileModules);
    }

    # If modules were on the command line then they are effectively forced to
    # process unless overridden by command line options as well. If phases
    # *were* overridden on the command line, then no update pass is required
    # (all modules already have correct phases)
    @modules = _updateModulePhases(@modules)
        unless @selectors;

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

    my @modulesFromCommand = @modules;

    my $moduleGraph = $self->_resolveModuleDependencyGraph(@modules);

    if (!$moduleGraph || !exists $moduleGraph->{graph}) {
        croak_runtime("Failed to resolve dependency graph");
    }

    if (exists $self->{debugFlags}->{'dependency-tree'}) {
        # Save for later introspection
        $self->{debugFlags}->{'dependency-tree'} = $moduleGraph->{graph};

        my $result = {
            dependencyInfo => $moduleGraph,
            modulesFromCommand => \@modulesFromCommand,
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

    my $result = {
        dependencyInfo => $moduleGraph,
        modulesFromCommand => \@modulesFromCommand,
        selectedModules => \@modules,
        build => 1,
    };

    # If debugging then don't build
    $result->{build} = 0 if exists $self->{debugFlags}->{'list-build'};

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
#           $ctx->getKDEDependenciesMetadataModule(),
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
        my $moduleResolver = $self->{module_resolver};
        my $dependencyResolver = ksb::DependencyResolver->new(sub {
            # Maps module names (what dep resolver has) to built ksb::Modules
            # (which we need), needs to include all option handling (cmdline,
            # rc-file, module-sets, etc)
            return $moduleResolver->resolveModuleIfPresent(shift);
        });
        my $branchGroup = $ctx->effectiveBranchGroup();

        for my $file ('dependency-data-common', "dependency-data-$branchGroup")
        {
            my $dependencyFile = $metadataModule->fullpath('source') . "/dependencies/$file";
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

# Similar to the old interactive runAllModulePhases. Actually performs the
# build for the modules selected by setModulesToProcess.
#
# Returns a Mojo::Promise that must be waited on. The promise resolves to
# return a single success/failure result; use the event handler for now to get
# more detail during a build.
sub startHeadlessBuild
{
    my $self = shift;
    my $ctx = $self->context();
    $ctx->statusMonitor()->createBuildPlan($ctx);

    my $promiseChain = ksb::PromiseChain->new;
    my $startPromise = Mojo::Promise->new;

    # These succeed or die outright
    $startPromise = _handle_updates ($ctx, $promiseChain, $startPromise);
    $startPromise = _handle_build   ($ctx, $promiseChain, $startPromise);

    die "Can't obtain build lock" unless $ctx->takeLock();

    # Install signal handlers to ensure that the lockfile gets closed.
    _installSignalHandlers(sub {
        @main::atexit_subs = (); # Remove their finish, doin' it manually
        $self->finish(5);
    });

    $startPromise->resolve; # allow build to start once control returned to evt loop
    my $promise = $promiseChain->makePromiseChain($startPromise)->finally(sub {
        my @results = @_;
        my $result = 0; # success, non-zero is failure

        # Must use ! here to make '0 but true' hack work
        $result = 1 if defined first { !($_->[0] // 1) } @results;

        $ctx->statusMonitor()->markBuildDone();
        $ctx->closeLock();

        my $failedModules = join(',', map { "$_" } $ctx->listFailedModules());
        if ($failedModules) {
            # We don't clear the list of failed modules on success so that
            # someone can build one or two modules and still use
            # --rebuild-failures
            $ctx->setPersistentOption('global', 'last-failed-module-list', $failedModules);
        }

        # TODO: Anything to do with this info at this point?
        my $workLoad = $self->workLoad();
        my $dependencyGraph = $workLoad->{dependencyInfo}->{graph};

        $ctx->storePersistentOptions();
        _cleanup_log_directory($ctx);

        # env driver is just the ~/.config/kde-env-*.sh, session driver is that + ~/.xsession
        if ($ctx->getOption('install-environment-driver') ||
            $ctx->getOption('install-session-driver'))
        {
            _installCustomSessionDriver($ctx);
        }

        # Check for post-build messages and list them here
        for my $m (@{$self->{modules}}) {
            my @msgs = $m->getPostBuildMessages();

            next unless @msgs;

            warning("\ny[Important notification for b[$m]:");
            warning("    $_") foreach @msgs;
        }

        return $result;
    });

    return $promise;
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
        # that was started by the user (for async mode)
        exit $exitcode;
    }

    $ctx->closeLock();
    $ctx->storePersistentOptions();

    my $logdir = $ctx->getLogDir();
    note ("Your logs are saved in file://y[$logdir]");

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
# Subroutine to update a list of modules.  Uses a Mojolicious event loop
# to run each update in a subprocess to avoid blocking the script.  Only
# one update process will exist at a given time.
#
# Parameters:
# 1. Build Context, which will be used to determine the module update list.
# 2. A PromiseChain for adding work items and dependencies.
# 3. A "start promise" that can be waited on for pre-update steps.
#
# This function accounts for every module in $ctx's update phase.
#
# Returns an updated start promise and can also throw exception on error
sub _handle_updates
{
    my ($ctx, $promiseChain, $start_promise) = @_;
    my $kdesrc = $ctx->getSourceDir();
    my @update_list = $ctx->modulesInPhase('update');

    return $start_promise unless @update_list;

    croak_runtime("SSH agent is not running but should be")
        unless _check_for_ssh_agent($ctx);

    # TODO: Extract this to a setup function that all updates/build depend upon
    whisper ("Creating source directory") unless -e $kdesrc;
    croak_runtime ("Unable to make directory r[$kdesrc]! $!")
        if (! -e $kdesrc && !super_mkdir ($kdesrc));

    for my $module (@update_list) {
        # sub must be defined here to capture $module in the loop
        my $updateSub = sub {
            return $module->runPhase_p('update',
                # called in child process, can block
                sub { return $module->update($ctx) },
                # called in this process, with results
                sub {
                    my (undef, $was_successful, $extras) = @_;
                    $module->setOption('#numUpdates', $extras->{update_count});
                    return $was_successful;
                }
            );
        };

        $promiseChain->addItem("$module/update", "network-queue", $updateSub);
    }

    return $start_promise;
}

# Throws an exception if essential build programs are missing as a sanity check.
sub _checkForEarlyBuildExit
{
    my $ctx = shift;
    my @modules = $ctx->modulesInPhase('build');

    # Check for absolutely essential programs now.
    if (!_checkForEssentialBuildPrograms($ctx) &&
        !exists $ENV{KDESRC_BUILD_IGNORE_MISSING_PROGRAMS})
    {
        error (" r[b[*] Aborting now to save a lot of wasted time.");
        error (" y[b[*] export KDESRC_BUILD_IGNORE_MISSING_PROGRAMS=1 and re-run (perhaps with --no-src)");
        error (" r[b[*] to continue anyways. If this check was in error please report a bug against");
        error (" y[b[*] kdesrc-build at https://bugs.kde.org/");

        croak_runtime ("Essential build programs are missing!");
    }
}

sub _openStatusFileHandle
{
    my $ctx = shift;
    my $outfile = pretending() ? '/dev/null'
                               : $ctx->getLogDir() . '/build-status';

    my $statusFile;
    open $statusFile, '>', $outfile or do {
        error (<<EOF);
	Unable to open output status file r[b[$outfile]
	You won't be able to use the g[--resume] switch next run.\n";
EOF
        $statusFile = undef;
    };

    return ($statusFile, $outfile);
}

# Function: _handle_build
#
# Subroutine to handle the build process.
#
# Parameters:
# 1. Build Context, which is used to determine list of modules to build.
# 2. A PromiseChain, which will have build items inserted and dependencies
#    added to the update phase as necessary.
# 3. A "start promise" that can be waited on for pre-build steps
#
# Assumes basic directory layout setup and updates completed
#
# If $builddir/$module/.refresh-me exists, the subroutine will completely
# rebuild the module (as if --refresh-build were passed for that module).
#
# Returns a new start promise, and can also throw exceptions on error
sub _handle_build
{
    my ($ctx, $promiseChain, $start_promise) = @_;
    my @modules = $ctx->modulesInPhase('build');
    my $result = 0;

    _checkForEarlyBuildExit($ctx); # exception-thrower

    my $num_modules = scalar @modules;
    my ($statusFile, $outfile) = _openStatusFileHandle($ctx);
    my $everFailed = 0;

    # This generates a bunch of subs but doesn't call them yet
    foreach my $module (@modules) {
        # Needs to happen in this loop to capture $module
        my $buildSub = sub {
            return if ($everFailed && $module->getOption('stop-on-failure'));

            my $fail_count = $module->getPersistentOption('failure-count') // 0;
            my $num_updates = int ($module->getOption('#numUpdates', 'module') // 1);

            # check for skipped updates, --no-src forces build-when-unchanged
            # even when ordinarily disabled
            if ($num_updates == 0
                && !$module->getOption('build-when-unchanged')
                && $fail_count == 0)
            {
                # TODO: Why is the param order reversed for these two?
                $ctx->statusMonitor()->markPhaseStart("$module", 'build');
                $ctx->markModulePhaseSucceeded('build', $module);

                return 'skipped';
            }

            # Can't build w/out blocking so return a promise instead, which ->build
            # already supplies
            return $module->build()->catch(sub {
                my $failureReason = shift;

                if (!$everFailed) {
                    # No failures yet, mark this as resume point
                    $everFailed = 1;
                    my $moduleList = join(', ', map { "$_" } ($module, @modules));
                    $ctx->setPersistentOption('global', 'resume-list', $moduleList);
                }

                ++$fail_count;

                # Force this promise chain to stay dead
                return Mojo::Promise->new->reject('build');
            })->then(sub {
                $fail_count = 0;
            })->finally(sub {
                $module->setPersistentOption('failure-count', $fail_count);
            });
        };

        $promiseChain->addItem("$module/build", 'cpu-queue', $buildSub);

        # If there's an update phase we need to depend on it and show status
        if (my $updatePromise = $promiseChain->promiseFor("$module/update")) {
            $promiseChain->addDep("$module/build", "$module/update");
        }
    };

    # Add to the build 'queue' for promise chain so that this runs only after all
    # other build jobs
    $promiseChain->addDep('@postBuild', 'cpu-queue', sub {
        if ($statusFile)
        {
            close $statusFile;

            # Update the symlink in latest to point to this file.
            my $logdir = $ctx->getSubdirPath('log-dir');
            if (-l "$logdir/latest/build-status") {
                safe_unlink("$logdir/latest/build-status");
            }
            symlink($outfile, "$logdir/latest/build-status");
        }

        return Mojo::Promise->new->reject if $everFailed;
        return 0;
    });

    return $start_promise->then(
        sub { $ctx->unsetPersistentOption('global', 'resume-list') });
}

# Function: _handle_async_build
#
# This subroutine special-cases the handling of the update and build phases, by
# performing them concurrently using forked processes and non-blocking I/O.
# See Mojo::Promise and Mojo::IOLoop::Subprocess
#
# This procedure will use multiple processes (the main process and separate
# processes for each update or build as they occur).
#
# Parameters:
# 1. Build Context to use, from which the module lists will be determined.
#
# Returns 0 on success, non-zero on failure.
sub _handle_async_build
{
    my ($ctx) = @_;
    my $result = 0;

    $ctx->statusMonitor()->createBuildPlan($ctx);

    my $promiseChain = ksb::PromiseChain->new;
    my $start_promise = Mojo::Promise->new;

    # These succeed or die outright
    eval {
        $start_promise = _handle_updates ($ctx, $promiseChain, $start_promise);
        $start_promise = _handle_build   ($ctx, $promiseChain, $start_promise);
    };

    if ($@) {
        error ("Caught an error $@ setting up to build");
        return 1;
    }

    my $chain = $promiseChain->makePromiseChain($start_promise)
        ->finally(sub {
            # Fail if we had a zero-valued result (indicates error)
            my @results = @_;

            # Must use ! here to make '0 but true' hack work
            $result = 1 if defined first { !($_->[0] // 1) } @results;

            $ctx->statusMonitor()->markBuildDone();
        });

    # Start the update/build process
    $start_promise->resolve;

    Mojo::IOLoop->stop; # Force the wait below to block
    $chain->wait;

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

    return unless @fail_list;

    debug ("Message is $message");
    debug ("\tfor ", join(', ', @fail_list));

    my $homedir = $ENV{'HOME'};

    warning ("\nr[b[<<<  PACKAGES $message  >>>]");

    for my $module (@fail_list)
    {
        my $logfile = $module->getOption('#error-log-file');

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
        $m->addPostBuildMessage("You can check https://build.kde.org/search/?q=$m to see if this is expected.");
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
    use Carp qw(confess);

    my $handlerRef = shift;
    my @signals = qw/HUP INT QUIT ABRT TERM PIPE/;

    foreach my $signal (@signals) {
        $SIG{$signal} = sub {
            confess ("Signal SIG$signal received, terminating.")
                unless $signal eq 'INT';
            $handlerRef->();
        };
    }
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
