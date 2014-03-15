package ksb::Application;

# Class: Application
#
# Contains the application-layer logic (i.e. creating a build context, reading
# options, parsing command-line, etc.)

use strict;
use warnings;
use v5.10;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

our $VERSION = '0.10';

use ksb::Debug;
use ksb::Util;
use ksb::BuildContext;
use ksb::BuildSystem::QMake;
use ksb::Module;
use ksb::ModuleSet;
use ksb::ModuleSet::KDEProjects;
use ksb::RecursiveFH;
use ksb::DependencyResolver 0.20;
use ksb::IPC::Pipe 0.20;
use ksb::IPC::Null;
use ksb::Updater::Git;
use ksb::Version qw(scriptVersion);

use List::Util qw(first min);
use File::Basename; # basename, dirname
use File::Glob ':glob';
use POSIX qw(:sys_wait_h _exit);
use Getopt::Long qw(GetOptionsFromArray :config gnu_getopt nobundling pass_through);
use IO::Handle;
use IO::Select;

### Package-specific variables (not shared outside this file).

my $SCRIPT_VERSION = scriptVersion();

# This is a hash since Perl doesn't have a "in" keyword.
my %ignore_list;  # List of packages to refuse to include in the build list.

use constant {
    # We use a named remote to make some git commands work that don't accept the
    # full path.
    KDE_PROJECT_ID   => 'kde-projects',          # git-repository-base for kde_projects.xml
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
        _base_pid       => $$, # See finish()
    }, $class;

    # Default to colorized output if sending to TTY
    ksb::Debug::setColorfulOutput(-t STDOUT);

    my @moduleList = $self->generateModuleList(@options);
    $self->{modules} = \@moduleList;

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
#  pendingOptions - hashref to hold parsed modules options to be applied later.
#    *Note* this must be done separately, it is not handled by this subroutine.
#    Global options will be stored in a hashref at $pendingOptions->{global}.
#    Module or module-set options will be stored in a hashref at
#    $pendingOptions->{$moduleName} (it will be necessary to disambiguate
#    later in the run whether it is a module set or a single module).
#
#    If the global option 'start-program' is set, then the selectors parameter
#    (see below) will not be selector at all, but will be a list of command
#    line options to pass to the chosen program to start (the program will be
#    the value of the 'start-program' option mentioned above).
#
#  selectors - listref to hold the list of module or module-set selectors to
#    build, in the order desired by the user. These will just be strings, the
#    caller will have to figure out whether the selector is a module or
#    module-set, and create any needed objects, and then set the recommended
#    options as listed in pendingOptions.
#
#    See pendingOptions for the special note about the value of this listref
#    when start-options is in effect.
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
    my ($pendingOptionsRef, $selectorsRef, $ctx, @options) = @_;
    my $phases = $ctx->phases();
    my @savedOptions = @options; # Copied for use in debugging.
    my $version = "kdesrc-build $SCRIPT_VERSION";
    my $author = <<DONE;
$version was written (mostly) by:
  Michael Pyne <mpyne\@kde.org>

Many people have contributed code, bugfixes, and documentation.

Please report bugs using the KDE Bugzilla, at http://bugs.kde.org/
DONE

    # Getopt::Long will store options in %foundOptions, since that is what we
    # pass in. To allow for custom subroutines to handle an option it is
    # required that the sub *also* be in %foundOptions... whereupon it will
    # promptly be overwritten if we're not careful. Instead we let the custom
    # subs save to %auxOptions, and read those in back over it later.
    my (%foundOptions, %auxOptions);
    %foundOptions = (
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
        pretend => sub {
            # Set pretend mode but also force the build process to run.
            $auxOptions{pretend} = 1;
            $foundOptions{'build-when-unchanged'} = 1;
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
                $pendingOptionsRef->{$module} //= { };
                $pendingOptionsRef->{$module}->{$option} = $value;
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
    GetOptionsFromArray(\@options, \%foundOptions,
        'version', 'author', 'help', 'disable-snapshots|no-snapshots',
        'install', 'uninstall', 'no-src|no-svn', 'no-install', 'no-build',
        'no-tests', 'build-when-unchanged|force-build', 'no-metadata',
        'verbose|v', 'quiet|quite|q', 'really-quiet', 'debug',
        'reconfigure', 'colorful-output|color!', 'async!',
        'src-only|svn-only', 'build-only', 'install-only', 'build-system-only',
        'rc-file=s', 'prefix=s', 'niceness|nice:10', 'ignore-modules=s{,}',
        'print-modules', 'pretend|dry-run|p', 'refresh-build',
        'start-program|run=s{,}',
        'revision=i', 'resume-from=s', 'resume-after=s',
        'stop-after=s', 'stop-before=s', 'set-module-option-value=s',

        # Special sub used (see above), but have to tell Getopt::Long to look
        # for strings
        (map { "$_:s" } (keys %ksb::BuildContext::defaultGlobalFlags)),

        # Default handling fine, still have to ask for strings.
        (map { "$_:s" } (keys %ksb::BuildContext::defaultGlobalOptions)),

        '<>', # Required to read non-option args
        );

    say "Warning: Unrecognized option $_" foreach @options;

    $pendingOptionsRef->{'global'} //= { };

    # To store the values we found, need to strip out the values that are
    # subroutines, as those are the ones we created. Alternately, place the
    # subs inline as an argument to the appropriate option in the
    # GetOptionsFromArray call above, but that's ugly too.
    my @readOptionNames = grep {
        ref($foundOptions{$_}) ne 'CODE'
    } (keys %foundOptions);

    # Slice assignment: $left{$key} = $right{$key} foreach $key (@keys), but
    # with hashref syntax everywhere.
    @{ $pendingOptionsRef->{'global'} }{@readOptionNames}
        = @foundOptions{@readOptionNames};

    @{ $pendingOptionsRef->{'global'} }{keys %auxOptions}
        = values %auxOptions;
}

# Method: _resolveSelectorsIntoModules
#
# Takes the provided list of module/module-set selectors, pending options to set,
# and module/module-sets to choose from (as read from rc-file) and selects the
# appropriate rc-file module/module-sets.
#
# Additionally the module-sets are expanded into modules.
#
# All pending options are set into each module. Global options are set by
# removing any existing rc-file option value, so you must setup the build context
# separately to have the needed option for this to work.
#
# Returns a list of <ksb::Modules> in build order.
#
# This is a package method, should be called as
# $app->_resolveSelectorsIntoModules
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  ctx - <BuildContext> in use. This function might call
#    setKDEProjectMetadataModule on the build context. If so, the project
#    metadata module should be updated before the build phase.
#
#  selectors - listref to hold the list of module or module-set selectors to
#    build, in the order desired by the user. The value of this parameter
#    WILL BE CHANGED by this function (each string name is replaced by matching
#    <Module> or <ModuleSet>.
#
#  modNew - reference to a subroutine to run that will accept a newly-made
#    <Module> and perform any needed setup. The idea is that this subroutine
#    will also setup any pending options (either from the cmdline or as rc-file
#    overlay). This could easily be an object except it doesn't seem to warrant
#    a full separate class.
#
#  rcFileModulesAndModuleSets - listref to a list of <Module> or <ModuleSet> (and
#    no other types) that can be selected from.
#
# Returns:
#  A list of <Module> to build (all module-sets expanded), with options
#  correctly setup from the rc-file and cmdline, in the same relative order as
#  determined in selectors.
#
#  If any passed-in selector does not match a module or module set from
#  rcFileModulesAndModuleSets then a <Module> will be created and assumed to
#  come from the kde-projects repository. A special option flag
#  '#guessed-kde-project' will be set for such modules.
sub _resolveSelectorsIntoModules
{
    my ($self, $ctx, $selectorsRef, $modNewRef, $rcFileModulesAndModuleSetsRef)
        = @_;
    my @modules = @{$selectorsRef};

    # Lookup modules/module-sets by name
    my %lookupTable =
        map { $_->name() => $_ } (@$rcFileModulesAndModuleSetsRef);

    # Separate lookup table for the use-modules entries for module-sets to allow
    # for partial module-set expansion. This and lookupTable *should* end up
    # with disjoint sets of module-names, at least as long as the user declared
    # their option-overriding module *after* the appropriate use-modules line.
    my %setEntryLookupTable;
    for my $moduleSet (grep { $_->isa('ksb::ModuleSet') } (@{$rcFileModulesAndModuleSetsRef}))
    {
        my @results = $moduleSet->moduleNamesToFind();

        # Have each use-module item point to the source module-set. The
        # parens in front of 'x' are semantically required for repetition!
        @setEntryLookupTable{@results} = ($moduleSet) x scalar @results;
    }

    my %expandedModuleSets; # Holds module-sets expanded on-the-fly

    # This is the meat of our procedure, so we wrap in a sub.
    # If not for the dependency on almost all of our params and the lifetime
    # requirements this could be a separate function.
    my $lookupSelector = sub {
        my $selector = shift;
        my $selectorName = $selector;

        # Module selectors beginning with '+' force treatment as a kde-projects
        # module, which means they won't be matched here (we're only looking for
        # sets).
        my $forcedToKDEProject = substr($selectorName, 0, 1) eq '+';
        substr($selectorName, 0, 1, '') if $forcedToKDEProject;

        # This test applies for both modules and (entire) module-sets. Note
        # that a partially-expanded module-set has its module results
        # re-inserted into lookup table though.
        if (exists $lookupTable{$selectorName}) {
            $selector = $lookupTable{$selectorName};
            $selector->{options}->{'#selected-by'} = 'name';
        }
        # This applies to module-sets when only a partial expansion is needed.
        elsif (exists $setEntryLookupTable{$selectorName}) {
            my $neededModuleSet = $setEntryLookupTable{$selectorName};

            # _expandModuleSets applies pending/cmdline options.
            if (!exists $expandedModuleSets{$neededModuleSet}) {
                my @moduleResults = _expandModuleSets(
                    $ctx, $modNewRef, $neededModuleSet);
                $expandedModuleSets{$neededModuleSet} = \@moduleResults;
            }

            $selector = first {
                $_->name() eq $selectorName
            } @{$expandedModuleSets{$neededModuleSet}};

            if (!$selector) {
                croak_internal("Didn't select a module that was here earlier in the code path. Please report a bug.");
            }

            $lookupTable{$selectorName} = $selector;
            $selector->setOption('#selected-by',
                'partial-expansion-' . $neededModuleSet->name());
        }
        elsif (ref $selector && $selector->isa('ksb::Module')) {
            # We couldn't find anything better than what we were provided,
            # just give it back.
            $selector = $selector;
            $selector->setOption('#selected-by', 'best-guess-after-full-search');
        }
        elsif ($forcedToKDEProject) {
            # Just assume it's a kde-projects module and expand away...
            $selector = ksb::ModuleSet::KDEProjects->new($ctx, '_cmdline');
            $selector->setModulesToFind($selectorName);
        }
        else {
            # Neither a named Module, ModuleSet, or use-modules entry within a
            # known ModuleSet. It's possible it might be a to-be-expanded
            # ModuleSet entry though, so create a shell Module for now and mark
            # it as a guess so we can see if it can be sorted out later.
            $selector = ksb::Module->new($ctx, $selectorName);
            $selector->phases()->phases($ctx->phases()->phases());

            if ($selectorName eq 'l10n') {
                $_->setScmType('l10n')
            }

            $selector->setScmType('proj');
            $selector->setOption('#guessed-kde-project', 1);
            $selector->setOption('#selected-by', 'initial-guess');
        }

        return $selector;
    };

    # We have to be careful to maintain order of selectors throughout.
    for my $selector (@modules) {
        $selector = $lookupSelector->($selector);
        # Perform module option setup
        $modNewRef->($selector) if $selector->isa('ksb::Module');
    }

    # Filter --resume-foo first so entire module-sets can be skipped.
    # Wrap in eval to catch runtime errors
    eval { @modules = _applyModuleFilters($ctx, @modules); };

    @modules = _expandModuleSets($ctx, $modNewRef, @modules);

    # If we have any 'guessed' modules then they had no obvious source in the
    # rc-file. But they might still be implicitly from one of our module-sets.
    # We want them to use ksb::Modules from the rc-file modules/module-sets
    # instead of our shell Modules, if possible.
    # But we didn't expand module-sets in rcFileModulesAndModuleSets
    # unconditionally, only ones that had been selected via the selectors.
    # Because of this we may need to go a step further and expand out all
    # remaining module-sets in rcFileModulesAndModuleSets if we have 'guess'
    # modules still left over, and see if we can then successfully match.
    if (first { $_->getOption('#guessed-kde-project', 'module') } @modules) {
        my @expandedOptionModules =
            _expandModuleSets($ctx, $modNewRef, @$rcFileModulesAndModuleSetsRef);
        %lookupTable = map { $_->name() => $_ } @expandedOptionModules;

        for my $guessedModule (grep {
            $_->getOption('#guessed-kde-project', 'module') } @modules)
        {
            # If the module we want could be found from within our rc-file
            # module-sets (even implicitly), use it. Otherwise assume
            # kde-projects and evaluate now.
            if (exists $lookupTable{$guessedModule->name()}) {
                $guessedModule = $lookupTable{$guessedModule->name()};
            }
            else {
                my $set = ksb::ModuleSet::KDEProjects->new($ctx, "guessed_from_cmdline");
                $set->setModulesToFind($guessedModule->name());

                my @results = _expandModuleSets($ctx, $modNewRef, $set);
                $guessedModule = shift @results;
            }
        }
    }

    return @modules;
}

# Generates the build context and module list based on the command line options
# and module selectors provided.
#
# After this function is called all module set selectors will have been
# expanded, and we will know if we need to download kde-projects metadata or
# not. Dependency resolution has not occurred.
#
# Returns: List of Modules to build.
sub generateModuleList
{
    my $self = shift;
    my @argv = @_;

    # Note: Don't change the order around unless you're sure of what you're
    # doing.

    my $ctx = $self->context();
    my $pendingOptions = { global => { }, };
    my $pendingGlobalOptions = $pendingOptions->{global};

    # Process --help, --install, etc. first.
    my @selectors;
    $self->_readCommandLineOptionsAndSelectors($pendingOptions, \@selectors,
        $ctx, @argv);

    my %ignoredSelectors;
    @ignoredSelectors{@{$pendingGlobalOptions->{'ignore-modules'}}} = undef;

    my @startProgramArgs = @{$pendingGlobalOptions->{'start-program'}};
    delete @{$pendingGlobalOptions}{qw/ignore-modules start-program/};

    # Everything else in pendingOptions should be OK to apply directly as a module
    # or context option.

    # rc-file needs special handling.
    if (exists $pendingGlobalOptions->{'rc-file'} && $pendingGlobalOptions->{'rc-file'}) {
        $ctx->setRcFile($pendingGlobalOptions->{'rc-file'});
    }

    # disable async if only running a single phase.
    $pendingGlobalOptions->{async} = 0 if (scalar $ctx->phases()->phases() == 1);

    my $fh = $ctx->loadRcFile();

    # _readConfigurationOptions will add pending global opts to ctx while ensuring
    # returned modules/sets have any such options stripped out. It will also add
    # module-specific options to any returned modules/sets.
    my @optionModulesAndSets = _readConfigurationOptions($ctx, $fh, $pendingOptions);
    close $fh;

    # Check if we're supposed to drop into an interactive shell instead.  If so,
    # here's the stop off point.

    if (@startProgramArgs)
    {
        # @modules is the command line arguments to pass in this case.
        # TODO: Have context setup environment variables here first.
        _executeCommandLineProgram(@startProgramArgs); # noreturn
    }

    # At this point we have our list of candidate modules / module-sets (as read in
    # from rc-file). The module sets have not been expanded into modules.
    # We also might have cmdline "selectors" to determine which modules or
    # module-sets to choose. First let's select module sets, and expand them.

    my @modules;
    my @globalCmdlineArgs = keys %{$pendingGlobalOptions};
    my $commandLineModules = scalar @selectors;

    my $newModuleSub = sub {
        my $module = shift;
        while (my ($k, $v) = each %{$pendingOptions->{$module->name()}}) {
            $module->setOption($k, $v);
        }

        # Just in case
        delete @{$module->{options}}{@globalCmdlineArgs};
    };

    if ($commandLineModules) {
        # select our modules and module-sets, and expand them out
        @modules = $self->_resolveSelectorsIntoModules(
            $ctx, \@selectors, $newModuleSub, \@optionModulesAndSets);

        ksb::Module->setModuleSource('cmdline');
    }
    else {
        # Build everything in the rc-file, in the order specified.

        # Check for ignored module-sets and modules (pre-expansion)
        @optionModulesAndSets = grep { ! exists $ignoredSelectors{$_->name()} } @optionModulesAndSets;
        @modules = _expandModuleSets($ctx, $newModuleSub, @optionModulesAndSets);

        if ($ctx->getOption('kde-languages')) {
            @modules = _expandl10nModules($ctx, @modules);
        }

        ksb::Module->setModuleSource('config');
    }

    # Check for ignored modules (post-expansion)
    @modules = grep { ! exists $ignoredSelectors{$_->name()} } @modules;

    # If modules were on the command line then they are effectively forced to
    # process unless overridden by command line options as well. If phases
    # *were* overridden on the command line, then no update pass is required
    # (all modules already have correct phases)
    @modules = _updateModulePhases(@modules) unless $commandLineModules;

    return @modules;
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
    my $metadataModule = $ctx->getKDEProjectMetadataModule();

    eval {
        my $sourceDir = $metadataModule->getSourceDir();
        super_mkdir($sourceDir);

        my $updateDesired = !$ctx->getOption('no-metadata') && $ctx->phases()->has('update');
        my $updateNeeded = (! -e "$sourceDir/dependency-data-common");
        my $lastUpdate = $ctx->getPersistentOption('global', 'last-metadata-update') // 0;

        if (!$updateDesired && $updateNeeded && (time - ($lastUpdate)) >= 7200) {
            warning (" r[b[*] Skipping build metadata update, but it hasn't been updated recently!");
        }

        if ($updateDesired && (!pretending() || $updateNeeded)) {
            $metadataModule->scm()->updateInternal();
            $ctx->setPersistentOption('global', 'last-metadata-update', time);
        }
    };

    if ($@) {
        warning (" b[r[*] Unable to download required metadata for build process");
        warning (" b[r[*] Will attempt to press onward...");
        warning (" b[r[*] Exception message: $@");
    }
}

# Returns a list of Modules in the proper build order according to the
# kde-build-metadata dependency information.
#
# The kde-build-metadata repository must have already been updated. The Modules
# to reorder must be passed as arguments.
sub _resolveModuleDependencies
{
    my $self = shift;
    my $ctx = $self->context();
    my $metadataModule = $ctx->getKDEProjectMetadataModule();
    my @modules = @_;

    @modules = eval {
        my $dependencyResolver = ksb::DependencyResolver->new();
        my $branchGroup = $ctx->getOption('branch-group', 'module') // '';
        if (!$branchGroup) {
            $branchGroup = $ctx->getOption('use-stable-kde')
                ? 'latest-qt4'
                : ($ctx->hasOption('use-stable-kde') # Could also be false if unset
                    ? 'kf5-qt5'      # Really set to false
                    : 'latest-qt4'); # Unset / this is default branch group if no option set
        }

        for my $file ('dependency-data-common', "dependency-data-$branchGroup")
        {
            my $dependencyFile = $metadataModule->fullpath('source') . "/$file";
            my $dependencies = pretend_open($dependencyFile)
                or die "Unable to open $dependencyFile: $!";

            debug (" -- Reading dependencies from $dependencyFile");
            $dependencyResolver->readDependencyData($dependencies);
            close $dependencies;
        }

        my @reorderedModules = $dependencyResolver->resolveDependencies(@modules);
        return @reorderedModules;
    };

    if ($@) {
        warning (" r[b[*] Problems encountered trying to sort modules into correct order:");
        warning (" r[b[*] $@");
        warning (" r[b[*] Will attempt to continue.");
    }

    return @modules;
}

# Runs all update, build, install, etc. phases. Basically this *is* the
# script.
sub runAllModulePhases
{
    my $self = shift;
    my $ctx = $self->context();
    my $metadataModule = $ctx->getKDEProjectMetadataModule();
    my @modules = $self->modules();

    $ctx->loadPersistentOptions();

    # If we have kde-build-metadata we must process it first, ASAP.
    if ($metadataModule) {
        $self->_downloadKDEProjectMetadata();

        $ctx->addToIgnoreList($metadataModule->scm()->ignoredModules());

        @modules = $self->_resolveModuleDependencies(@modules);
    }

    # Filter --resume-foo options. This might be a second pass, but that should
    # be OK since there's nothing different going on from the first pass (in
    # _resolveSelectorsIntoModules) in that event.
    @modules = _applyModuleFilters($ctx, @modules);

    if ($ctx->getOption('print-modules')) {
        info (" * Module list", $metadataModule ? " in dependency order" : '');
        say "$_" foreach @modules;
        return 0; # Abort execution early!
    }

    # Add to global module list now that we've filtered everything.
    $ctx->addModule($_) foreach @modules;

    my $runMode = $self->runMode();
    my $result;

    my @update_list = map { $_->name() } ($ctx->modulesInPhase('update'));
    my @build_list = map { $_->name() } ($ctx->modulesInPhase('build'));

    debug ("Update list is ", join (', ', @update_list));
    debug ("Build list is ", join (', ', @build_list));

    if ($runMode eq 'build')
    {
        # No packages to install, we're in build mode

        # What we're going to do is fork another child to perform the source
        # updates while we build.  Setup for this first by initializing some
        # shared memory.
        my $ipc = 0;

        if ($ctx->getOption('async'))
        {
            $ipc = ksb::IPC::Pipe->new();
        }

        if (!$ipc)
        {
            $ipc = ksb::IPC::Null->new();
            whisper ("Using no IPC mechanism\n");

            note ("\n b[<<<  Update Process  >>>]\n");
            $result = _handle_updates ($ipc, $ctx);

            note (" b[<<<  Build Process  >>>]\n");
            $result = _handle_build ($ipc, $ctx) || $result;
        }
        else
        {
            $result = _handle_async_build ($ipc, $ctx);
            $ipc->outputPendingLoggedMessages();
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
    _output_failed_module_lists($ctx);
    _installCustomSessionDriver($ctx) if $ctx->getOption('install-session-driver');

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
    # of the flags is dependant on the option.
    my ($option, $value) = ($input =~ /^\s*     # Find all spaces
                            ([-\w]+) # First match, alphanumeric, -, and _
                            # (?: ) means non-capturing group, so (.*) is $value
                            # So, skip spaces and pick up the rest of the line.
                            (?:\s+(.*))?$/x);

    $value //= '';

    # Simplify whitespace.
    $value =~ s/\s+$//;
    $value =~ s/^\s+//;
    $value =~ s/\s+/ /g;

    # Check for false keyword and convert it to Perl false.
    $value = 0 if lc($value) eq 'false';

    # Replace reference to global option with their value.
    # The regex basically just matches ${option-name}.
    my ($sub_var_name) = ($value =~ $optionRE);
    while ($sub_var_name)
    {
        my $sub_var_value = $ctx->getOption($sub_var_name) || '';
        if(!$ctx->hasOption($sub_var_value)) {
            warning (" *\n * WARNING: $sub_var_name is not set at line y[$.]\n *");
        }

        debug ("Substituting \${$sub_var_name} with $sub_var_value");

        $value =~ s/\${$sub_var_name}/$sub_var_value/g;

        # Replace other references as well.  Keep this RE up to date with
        # the other one.
        ($sub_var_name) = ($value =~ $optionRE);
    }

    # Replace tildes with home directory.
    1 while ($value =~ s"(^|:|=)~/"$1$ENV{'HOME'}/");

    return ($option, $value);
}

# Reads in the options from the config file and adds them to the option store.
# The first parameter is a BuildContext object to use for creating the returned
#     ksb::Module under.
# The second parameter is a reference to the file handle to read from.
# The third parameter is the module name. It can be either an
# already-constructed ksb::Module object (in which case it is used directly and any
# options read for the module are applied directly to the object), or it can be
# a string containing the module name (in which case a new ksb::Module object will
# be created). For global options the module name should be 'global', or just
# pass in the BuildContext for this param as well.
#
# The return value is the ksb::Module with options set as given in the configuration
# file for that module. If global options were being read then a BuildContext
# is returned (but that is-a ksb::Module anyways).
sub _parseModuleOptions
{
    my ($ctx, $fileReader, $moduleOrName) = @_;
    assert_isa($ctx, 'ksb::BuildContext');

    my $rcfile = $ctx->rcFile();
    my $module;

    # Figure out what objects to store options into. If given, just use
    # that, otherwise use context or a new ksb::Module depending on the name.
    if (ref $moduleOrName) {
        $module = $moduleOrName;
        assert_isa($module, 'ksb::Module');
    }
    elsif ($moduleOrName eq 'global') {
        $module = $ctx;
    }
    else {
        $module = ksb::Module->new($ctx, $moduleOrName);
    }

    my $endWord = $module->isa('ksb::BuildContext') ? 'global' : 'module';
    my $endRE = qr/^end[\w\s]*$/;

    # Read in each option
    while ($_ = _readNextLogicalLine($fileReader))
    {
        last if m/$endRE/;

        # Sanity check, make sure the section is correctly terminated
        if(/^(module\s|module$)/)
        {
            error ("Invalid configuration file $rcfile at line $.\nAdd an 'end $endWord' before " .
                   "starting a new module.\n");
            die make_exception('Config', "Invalid $rcfile");
        }

        my ($option, $value) = _splitOptionAndValue($ctx, $_);

        # Handle special options.
        if ($module->isa('ksb::BuildContext') && $option eq 'git-repository-base') {
            # This will be a hash reference instead of a scalar
            my ($repo, $url) = ($value =~ /^([a-zA-Z0-9_-]+)\s+(.+)$/);
            $value = $ctx->getOption($option) || { };

            if (!$repo || !$url) {
                error (<<"EOF");
The y[git-repository-base] option at y[b[$rcfile:$.]
requires a repository name and URL.

e.g. git-repository base y[b[kde] g[b[git://anongit.kde.org/]

Use this in a "module-set" group:

e.g.
module-set kdesupport-set
  repository y[b[kde]
  use-modules automoc akonadi soprano attica
end module-set
EOF
                die make_exception('Config', "Invalid git-repository-base");
            }

            $value->{$repo} = $url;
        }
        # Read ~~ as "is in this list:"
        elsif ($option ~~ [qw(git-repository-base use-modules ignore-modules)]) {
            error (" r[b[*] module b[$module] (near line $.) should be declared as module-set to use b[$option]");
            die make_exception('Config', "Option $option can only be used in module-set");
        }
        elsif ($option eq 'filter-out-phases') {
            for my $phase (split(' ', $value)) {
                $module->phases()->filterOutPhase($phase);
            }

            next; # Don't fallthrough to set the option
        }

        $module->setOption($option, $value);
    }

    return $module;
}

# Reads in a "moduleset".
#
# First parameter is the build context.
# Second parameter is the filehandle to the config file to read from.
# Third parameter is the name of the moduleset, which is really the name
# of the base repository to use (this can be left empty).
#
# Returns a ksb::ModuleSet describing the module-set encountered, which may
# need to be further expanded (see ksb::ModuleSet::convertToModules).
sub _parseModuleSetOptions
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $fileReader = shift;
    my $moduleSetName = shift || '';
    my $rcfile = $ctx->rcFile();

    my $startLine = $.; # For later error messages
    my $internalModuleSetName =
        $moduleSetName || "<module-set at line $startLine>";

    my $moduleSet = ksb::ModuleSet->new($ctx, $internalModuleSetName);
    my %optionSet; # We read all options, and apply them to all modules

    while($_ = _readNextLogicalLine($fileReader)) {
        last if /^end\s+module(-?set)?$/;

        my ($option, $value) = _splitOptionAndValue($ctx, $_);

        if ($option eq 'use-modules') {
            my @modules = split(' ', $value);

            if (not @modules) {
                error ("No modules were selected for the current module-set");
                error ("in the y[use-modules] on line $. of $rcfile");
                die make_exception('Config', 'Invalid use-modules');
            }

            $moduleSet->setModulesToFind(@modules);
        }
        elsif ($option eq 'ignore-modules') {
            my @modulesToIgnore = split(' ', $value);

            if (not @modulesToIgnore) {
                error ("No modules were selected for the current module-set");
                error ("in the y[ignore-modules] on line $. of $rcfile");
                die make_exception('Config', 'Invalid ignore-modules');
            }

            $moduleSet->setModulesToIgnore(@modulesToIgnore);
        }
        elsif ($option eq 'set-env') {
            ksb::Module::processSetEnvOption(\%optionSet, $option, $value);
        }
        else {
            $optionSet{$option} = $value;
        }
    }

    $moduleSet->setOptions(\%optionSet);

    # Check before we use this module set whether the user did something silly.
    my $repoSet = $ctx->getOption('git-repository-base');
    if (!exists $optionSet{'repository'}) {
        error (<<EOF);

There was no repository selected for the module-set declared on line $startLine
of $rcfile.

A repository is needed to determine where to download the source code from.

Most will want to use the b[g[kde-projects] repository. See also
http://kdesrc-build.kde.org/documentation/kde-modules-and-selection.html#module-sets
EOF
        die make_exception('Config', 'Missing repository option');
    }

    if (($optionSet{'repository'} ne KDE_PROJECT_ID) &&
        not exists $repoSet->{$optionSet{'repository'}})
    {
        my $projectID = KDE_PROJECT_ID;
        my $moduleSetId = $moduleSetName ? "module-set ($moduleSetName)"
                                         : "module-set";

        error (<<EOF);
There is no repository assigned to y[b[$optionSet{repository}] when assigning a
$moduleSetId on line $startLine of $rcfile.

These repositories are defined by g[b[git-repository-base] in the global
section of $rcfile.
Make sure you spelled your repository name right!

If you are trying to pull the module information from the KDE
http://projects.kde.org/ website, please use b[$projectID] for the value of
the b[repository] option.
EOF

        die make_exception('Config', 'Unknown repository base');
    }

    if ($optionSet{'repository'} eq KDE_PROJECT_ID) {
        # Perl-specific note! re-blessing the module set into the right 'class'
        # You'd probably have to construct an entirely new object and copy the
        # members over in other languages.
        bless $moduleSet, 'ksb::ModuleSet::KDEProjects';
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
#  any pending options (see pendingGlobalOptions).
#
#  filehandle - The I/O object to read from. Must handle _eof_ and _readline_
#  methods (e.g. <IO::Handle> subclass).
#
#  pendingOptions - hashref holding key/value pairs of pending
#  options. Any read-in global options matching a key in this hash will be
#  ignored in the result list (i.e. the global options will mask the read-in
#  ones), except for ctx, which will have its options modified to match the
#  pending ones.
#
#  Conversely, any module/set options to be applied in pendingOptions are
#  applied before this function returns. Options for a module are removed from
#  pendingOptions when they are applied, so that you can tell which options have
#  not yet been applied.
#
# Returns:
#  @module - Heterogenous list of <Modules> and <ModuleSets> defined in the
#  configuration file. No module sets will have been expanded out (either
#  kde-projects or standard sets).
#
# Throws:
#  - Config exceptions.
sub _readConfigurationOptions
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $fh = shift;
    my $pendingOptionsRef = shift;
    my @module_list;
    my $rcfile = $ctx->rcFile();
    my ($option, %readModules);

    my $fileReader = ksb::RecursiveFH->new();
    $fileReader->pushBasePath(dirname($rcfile)); # rcfile should already be absolute
    $fileReader->addFilehandle($fh);

    # Read in global settings
    while ($_ = $fileReader->readLine())
    {
        s/#.*$//;       # Remove comments
        s/^\s*//;       # Remove leading whitespace
        next if (/^\s*$/); # Skip blank lines

        # First command in .kdesrc-buildrc should be a global
        # options declaration, even if none are defined.
        if (not /^global\s*$/)
        {
            error ("Invalid configuration file: $rcfile.");
            error ("Expecting global settings section at b[r[line $.]!");
            die make_exception('Config', 'Missing global section');
        }

        # Now read in each global option.
        _parseModuleOptions($ctx, $fileReader, 'global');
        while (my ($k, $v) = each %{$pendingOptionsRef->{global}}) {
            $ctx->setOption($k, $v);
        }

        last;
    }

    my $using_default = 1;
    my @pendingOptsKeys = keys %{$pendingOptionsRef->{global}};
    my %seenModules; # NOTE! *not* module-sets, *just* modules.
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

            # A moduleset can give us more than one module to add.
            $newModule = _parseModuleSetOptions($ctx, $fileReader, $modulename);

            # Save 'use-modules' entries so we can see if later module decls
            # are overriding/overlaying their options.
            my @moduleSetItems = $newModule->moduleNamesToFind();
            @seenModuleSetItems{@moduleSetItems} = ($newModule) x scalar @moduleSetItems;
        }
        # Duplicate module entry? (Note, this must be checked before the check
        # below for 'options' sets)
        elsif (exists $seenModules{$modulename}) {
            # Overwrite options set for existing modules.
            # But allow duplicate 'options' declarations without error.
            if ($type ne 'options') {
                warning ("Don't use b[r[module $modulename] on line $., use b[g[options $modulename]");
            }

            $newModule = $seenModules{$modulename};

            # _parseModuleOptions will re-use newModule, but we still need to
            # be careful not to mask cmdline options in pendingOptsKeys.
            _parseModuleOptions($ctx, $fileReader, $newModule);

            delete @{$newModule->{options}}{@pendingOptsKeys};

            next; # Skip all the stuff below
        }
        # Module override (for use-modules from a module-set), or option overrride?
        elsif ($type eq 'options' || exists $seenModuleSetItems{$modulename}) {
            # Parse the modules...
            $newModule = _parseModuleOptions($ctx, $fileReader, "#overlay_$modulename");

            # but only keep the options. Any existing pending options came from
            # cmdline so do not overwrite existing keys.
            $pendingOptionsRef->{$modulename} //= { };
            my $moduleOptsRef = $pendingOptionsRef->{$modulename};
            while (my ($k, $v) = each %{$newModule->{options}}) {
                $moduleOptsRef->{$k} = $v unless exists $moduleOptsRef->{$k};
            }

            # Don't mask global cmdline options.
            delete @{$moduleOptsRef}{@pendingOptsKeys};

            # TODO: Remove compat handling of 'module $foo' as 'options $foo',
            # probably 2014-04-01?
            if ($type ne 'options') {
                warning ("Don't use b[r[module $modulename] on line $., use b[g[options $modulename]");
            }

            next; # Don't add to module list
        }
        else {
            $newModule = _parseModuleOptions($ctx, $fileReader, $modulename);
            $seenModules{$modulename} = $newModule;
        }

        delete @{$newModule->{options}}{@pendingOptsKeys};
        push @module_list, $newModule;

        # Don't build default modules if user has their own wishes.
        $using_default = 0;
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

# Function: _spliceOptionModules
#
# Replaces any modules in a given list that have a name matching that of a
# "option module" with that option module inline. Modules that have no "option
# module" match are unchanged.
#
# Parameters:
#  @$modules - Listref of modules to potentially splice in replacements of.
#  @$optionModules - Listref to list of the "option" modules (and module-sets),
#  which should be of the same level of kde-project expansion as @$modules. A
#  module-set might be spliced in to replace a named module.
#
# Returns:
#  Nothing.
sub _spliceOptionModules
{
    my ($modulesRef, $optionModulesRef) = @_;

    for (my $i = 0; $i < scalar @{$modulesRef}; $i++) {
        my $module = ${$modulesRef}[$i];

        my ($optionModule) = grep {
            $_->name() eq $module->name()
        } @{$optionModulesRef};

        splice @$modulesRef, $i, 1, $optionModule if defined $optionModule;
    }
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
        return 0;
    }

    if (not _check_for_ssh_agent($ctx))
    {
        $ipc->sendIPCMessage(ksb::IPC::ALL_FAILURE, "ssh-failure");
        return 1;
    }

    if (grep { $_->scm()->isa('ksb::Updater::Git') } @update_list) {
        ksb::Updater::Git::verifyGitConfig();
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

    $ipc->close();
    return $hadError;
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

    my $outfile = pretending() ? undef
                               : $ctx->getLogDir() . '/build-status';

    open (STATUS_FILE, '>', $outfile // '/dev/null') or do {
        error (<<EOF);
	Unable to open output status file r[b[$outfile]
	You won't be able to use the g[--resume] switch next run.\n";
EOF
        $outfile = undef;
    };

    my $num_modules = scalar @modules;
    my $i = 1;

    while (my $module = shift @modules)
    {
        my $moduleName = $module->name();
        my $moduleSet = $module->moduleSet()->name();
        my $modOutput = "$module";

        if (debugging(ksb::Debug::WHISPER)) {
            $modOutput .= " (build system " . $module->buildSystemType() . ")"
        }

        if ($moduleSet) {
            note ("Building g[$modOutput] from g[$moduleSet] ($i/$num_modules)");
        }
        else {
            note ("Building g[$modOutput] ($i/$num_modules)");
        }

        if (debugging(ksb::Debug::WHISPER) && exists $module->{deps_were}) {
            note ("\tDeps from current build were: b[", join(', ', @{$module->{deps_were}}));
        }

        $ctx->resetEnvironment();
        $module->setupEnvironment();

        my $start_time = time;

        # If using IPC, read in the contents of the message buffer, and wait
        # for completion of the source update if necessary.

        my ($resultStatus, $message) = $ipc->waitForModule($module);

        if ($resultStatus eq 'failed') {
            $result = 1;
            $ctx->markModulePhaseFailed('update', $module);
            print STATUS_FILE "$module: Failed on update.\n";

            # Increment failed count to track when to start bugging the
            # user to fix stuff.
            my $fail_count = $module->getPersistentOption('failure-count') // 0;
            ++$fail_count;
            $module->setPersistentOption('failure-count', $fail_count);

            error ("\tUnable to update r[$module], build canceled.");
            next;
        }
        elsif ($resultStatus eq 'skipped') {
            # i.e. build should be skipped.
            info ("\tNo changes to source code.");
        }
        elsif ($resultStatus eq 'success') {
            note ("\tSource update complete for g[$module]: $message");
        }

        # Skip actually building a module if the user has selected to skip
        # builds when the source code was not actually updated. But, don't skip
        # if we didn't successfully build last time.
        if (!$module->getOption('build-when-unchanged') &&
            $resultStatus eq 'skipped' &&
            ($module->getPersistentOption('failure-count') // 0) == 0)
        {
            note ("\tSkipping g[$module], its source code has not changed.");
            $i++;
            push @build_done, $moduleName; # Make it show up as a success
            next;
        }

        if ($module->build())
        {
            my $elapsed = prettify_seconds(time - $start_time);
            print STATUS_FILE "$module: Succeeded after $elapsed.\n";
            $module->setPersistentOption('last-build-rev', $module->currentScmRevision());
            $module->setPersistentOption('failure-count', 0);

            info ("\tOverall time for g[$module] was g[$elapsed].");
            push @build_done, $moduleName;
        }
        else
        {
            my $elapsed = prettify_seconds(time - $start_time);
            print STATUS_FILE "$module: Failed after $elapsed.\n";

            info ("\tOverall time for r[$module] was g[$elapsed].");
            $ctx->markModulePhaseFailed('build', $module);
            $result = 1;

            # Increment failed count to track when to start bugging the
            # user to fix stuff.

            my $fail_count = $module->getPersistentOption('failure-count') // 0;
            ++$fail_count;
            $module->setPersistentOption('failure-count', $fail_count);

            if ($module->getOption('stop-on-failure'))
            {
                note ("\n$module didn't build, stopping here.");
                return 1; # Error
            }
        }

        $i++;
    }
    continue # Happens at the end of each loop and on next
    {
        print "\n"; # Space things out
    }

    $ipc->close();

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

    if (not pretending())
    {
        # Print out results, and output to a file
        my $kdesrc = $ctx->getSourceDir();
        open BUILT_LIST, ">$kdesrc/successfully-built";
        foreach my $module (@build_done)
        {
            info ("$module");
            print BUILT_LIST "$module\n";
        }
        close BUILT_LIST;
    }
    else
    {
        # Just print out the results
        info ('g[', join ("]\ng[", @build_done), ']');
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

        if ($updaterPid) {
            $updaterToMonitorIPC->setSender();
            ksb::Debug::setIPC($updaterToMonitorIPC);

            # Avoid calling close subroutines in more than one routine.
            POSIX::_exit (_handle_updates ($updaterToMonitorIPC, $ctx));
        }
        else {
            $ipc->setSender();
            $updaterToMonitorIPC->setReceiver();

            $ipc->setLoggedModule('#monitor#'); # This /should/ never be used...
            ksb::Debug::setIPC($ipc);

            # Avoid calling close subroutines in more than one routine.
            my $result = _handle_monitoring ($ipc, $updaterToMonitorIPC);

            waitpid ($updaterPid, 0);
            $result = 1 if $? != 0;

            POSIX::_exit ($result);
        }
    }
    else {
        # Still the parent, let's do the build.
        $ipc->setReceiver();
        $result = _handle_build ($ipc, $ctx);
    }

    # Exit code is in $?.
    waitpid ($monitorPid, 0);

    $result = 1 if $? != 0;

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

# Function: _expandModuleSets
#
# Replaces <ModuleSets> in an input list from the command line that name
# module-sets listed in the configuration file, and returns the new list.
#
# <Modules> are ignored if found in the input list, and transferred to the
# output list in the same relative order.
#
# This function may result in kde-projects metadata being downloaded and
# processed.
#
# Parameters:
#  $ctx - <BuildContext> in use for this script execution. Additionally this
#    method might call setKDEProjectMetadataModuleNeeded on the $ctx.
#  $modNew  - Reference to a subroutine to be run for every new <Module>
#    created. See _resolveSelectorsIntoModules for full details.
#  @modules - list of <Modules>, <ModuleSets> to be expanded.
#
# Returns:
#  @modules - List of <Modules> with any module-sets expanded into <Modules>.
sub _expandModuleSets
{
    my ($ctx, $modNewSub, @buildModuleList) = @_;

    my $filter = sub {
        if ($_->isa('ksb::ModuleSet')) {
            return map { $modNewSub->($_); $_ } ($_->convertToModules($ctx));
        }

        return $_;
    };

    my @moduleResults = map { &$filter } (@buildModuleList);

    if (first { $_->scmType() eq 'proj' } @moduleResults) {
        $ctx->setKDEProjectMetadataModuleNeeded();
    }

    return @moduleResults;
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

    debug ("Message is $message");
    debug ("\tfor ", join(', ', @fail_list));

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

    # This list should correspond to the possible phase names (although
    # it doesn't yet since the old code didn't, TODO)
    for my $phase ($ctx->phases()->phases())
    {
        my @failures = $ctx->failedModulesInPhase($phase);
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
                  $ctx->getOption($1, 'module') ||
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
    my @searchPaths = ($RealBin, map { "$_/kdesrc-build" } ($xdgDataHome, @xdgDataDirs));

    s{/+$}{}   foreach @searchPaths; # Remove trailing slashes
    s{//+}{/}g foreach @searchPaths; # Remove duplicate slashes

    my $envScript = first { -f $_ } (
        map { "$_/sample-kde-env-master.sh" } @searchPaths
    );
    my $sessionScript = first { -f $_ } (
        map { "$_/sample-xsession.sh" } @searchPaths
    );
    my $userSample = first { -f $_ } (
        map { "$_/sample-kde-env-user.sh" } @searchPaths
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
        'xsession-digest');

    if (!pretending()) {
        if (! -e "$destDir/kde-env-user.sh") {
            copy($userSample, "$destDir/kde-env-user.sh") or do {
                warning ("b[*] Unable to install b[$userSample]: $!");
                warning ("b[*] You should create b[~/.config/kde-env-user.sh] yourself or fix the error and re-run");
            };
        }

        chmod (0744, "$ENV{HOME}/.xsession") or do {
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
        );

        my $programPath = absPathToExecutable($prog);

        # qmake is not necessarily named 'qmake'
        if (!$programPath && $prog eq 'qmake') {
            $programPath = ksb::BuildSystem::QMake::absPathToQMake();
        }

        if (!$programPath) {
            # Don't complain about Qt if we're building it...
            if ($prog eq 'qmake' && (
                    grep { $_->buildSystemType() eq 'Qt' } (@buildModules)) ||
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

You can also see the
http://techbase.kde.org/Getting_Started/Build/Distributions page for
information specific to your distribution (although watch for outdated
information :( ).
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

# Shows a help message and version. Does not exit.
sub _showHelpMessage
{
    print <<DONE;
kdesrc-build $SCRIPT_VERSION
http://kdesrc-build.kde.org/

This script automates the download, build, and install process for KDE software
using the latest available source code.

You should first setup a configuration file (~/.kdesrc-buildrc). You can do
this by running the kdesrc-build-setup program, which should be included with
this one.  You can also copy the kdesrc-buildrc-sample file (which should be
included) to ~/.kdesrc-buildrc.

Basic synopsis, after setting up .kdesrc-buildrc:
\$ $0 [--options] [module names]

The module names can be either the name of an individual module (as set in your
configuration with a module declaration, or a use-modules declaration), or of a
module set (as set with a module-set declaration).

If you don\'t specify any particular module names, then every module you have
listed in your configuration will be built, in the order listed.

Copyright (c) 2003 - 2013 Michael Pyne <mpyne\@kde.org>, and others.

The script is distributed under the terms of the GNU General Public License
v2, and includes ABSOLUTELY NO WARRANTY!!!

Options:
    --no-src             Skip contacting the source server.
    --no-build           Skip the build process.
    --no-install         Don't automatically install after build.

    --pretend            Don't actually take major actions, instead describe
                         what would be done.

    --src-only           Only update the source code (Identical to --no-build
                         at this point).
    --build-only         Build only, don't perform updates or install.

    --install-only       Only install the already compiled code, this is equivalent
    --install            to make install/fast in CMake. Useful for example when we
                         want to clean the install directory but we do not want to
                         re-compile everything.

    --rc-file=<filename> Read configuration from filename instead of default.

    --resume-from=<pkg>  Skips modules until just before the given package,
                         then operates as normal.
    --resume-after=<pkg> Skips modules up to and including the given package,
                         then operates as normal.

    --stop-before=<pkg>  Skips the given package and all later packages.
    --stop-after=<pkg>   Skips all packages after the given package.

    --reconfigure        Run CMake/configure again, but don't clean the build
                         directory.
    --build-system-only  Create the build infrastructure, but don't actually
                         perform the build.

    --<option>=          Any unrecognized options override an existing global
                         configuration value, if present.

    --set-module-option-value=<module>,<option>,<value>
        This option allows you to override an option for a given module, so
        that you don't have to change it in the configuration file temporarily.
        Use a module name of 'global' for the global configuration.

    --pretend (or -p)    Don't actually contact the source server, run make,
                         or create/delete files and directories.  Instead,
                         output what the script would have done.
    --refresh-build      Start the build from scratch.

    --verbose            Print verbose output

    --help               You\'re reading it. :-)
    --version            Output the program version.

You can get more help by going online to http://kdesrc-build.kde.org/ to view
the online documentation.  If you have installed kdesrc-build you may also be
able to view the documentation using KHelpCenter or Konqueror at the URL
help:/kdesrc-build, or using the man page by typing "man kdesrc-build".
DONE
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

1;
