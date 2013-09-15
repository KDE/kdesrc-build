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
use ksb::Module;
use ksb::RecursiveFH;
use ksb::Version qw(scriptVersion);

use List::Util qw(first min);

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

    return $self;
}

# Runs the pre-initialization phase and takes the kdesrc-build lock. Once this
# function successfully completes it is required for the main process to call
# finish() to remove the lock.
sub generateModuleList
{
    my $self = shift;
    my @argv = @_;

    # Note: Don't change the order around unless you're sure of what you're
    # doing.

    my $ctx = $self->context();
    my $pendingOptions = { };

    debug ("+++ Reached pre-init phase");

    # Process --help, --install, etc. first.
    my @modules = $self->_processCmdlineArguments($ctx, $pendingOptions, @argv);

    debug ("--- Arguments read: ", scalar @modules, " command line modules");

    # Output time once we know if pretending or not.
    my $time = localtime;
    info ("Script started processing at g[$time]") unless pretending();

    # Change name and type of command line entries beginning with + to force
    # them to be XML project modules.
    foreach (@modules) {
        if (substr($_->{name}, 0, 1) eq '+') {
            debug ("Forcing ", $_->name(), " to be an XML module");
            $_->setScmType('proj');
            substr($_->{name}, 0, 1) = ''; # Remove first char
        }
    }

    my $fh = $ctx->loadRcFile();

    # If we're still here, read the options
    my @optionModulesAndSets = _readConfigurationOptions($ctx, $fh);
    close $fh;
    debug ("--- Config file read: ", scalar @optionModulesAndSets, " modules/module sets.");
    debug ("   --- " , (scalar grep { $_->isa('ksb::ModuleSet') } @optionModulesAndSets) , " are module sets.");

    # Modify the options read from the rc-file to have the pending changes from
    # the command line.
    foreach my $pendingModule (keys %{$pendingOptions}) {
        my $options = ${$pendingOptions}{$pendingModule};
        my ($module) = grep {
            $_->isa('ksb::Module') && $pendingModule eq $_->name()
        } (@optionModulesAndSets);

        if (!$module) {
            warning ("Tried to set options for unknown module b[y[$pendingModule]");
            next;
        }

        while (my ($key, $value) = each %{$options}) {
            $module->setOption($key, $value);
        }
    }

    # Check if we're supposed to drop into an interactive shell instead.  If so,
    # here's the stop off point.

    if (my $prog = $ctx->getOption('#start-program'))
    {
        # @modules is the command line arguments to pass in this case.
        _executeCommandLineProgram($prog, @modules);
    }

    my $commandLineModules = scalar @modules;
    my $metadataModule;

    # Allow named module-sets to be given on the command line.
    if ($commandLineModules) {
        # Copy ksb::Module and ksb::ModuleSet objects from the ones created by
        # _readConfigurationOptions since their module-type will actually be set.
        _spliceOptionModules(\@modules, \@optionModulesAndSets);
        debug ("--- spliced rc-file modules/sets into command line modules");
        debug ("   --- now ", scalar @modules, " modules present");

        # After this splicing, the only bare ksb::Modules with a 'proj'
        # scm type should be the ones from the command line that we got from
        # _processCmdlineArguments.

        # Modify l10n module inline, if present.
        for (@modules) {
            if ($_->name() eq 'l10n' && $_->isa('ksb::Module')) {
                $_->setScmType('l10n')
            }
        }

        # Filter --resume-foo first so entire module-sets can be skipped.
        # Wrap in eval to catch runtime errors
        eval { @modules = _applyModuleFilters($ctx, @modules); };

        debug ("--- Applied command-line --resume-foo pass, ", scalar @modules, " remain.");
        debug ("   --- " , (scalar grep { $_->isa("ksb::ModuleSet") } @modules) , " are module sets.");

        ($metadataModule, @modules) = _expandModuleSets($ctx, @modules);

        debug ("--- Expanded command-line module sets into ", scalar @modules, " modules.");
        debug ("   --- Metadata module needed? ", $metadataModule ? "Yes" : "No");

        # If we have any 'guessed' modules they came from the command line. We
        # want them to use ksb::Modules that came from
        # _readConfigurationOptions() instead of ones from _processCmdlineArguments(),
        # if any are available. But we don't expand module-sets from
        # _readConfigurationOptions unconditionally, only ones where the name
        # matched between the command line and rc-file, so the previous
        # _spliceOptionModules might not have found them. (e.g. if you named a
        # module on the command line that isn't named directly in the rc file
        # but would eventually be found implicitly). To make this work we have
        # to expand out our rc-file Modules and try splicing again.
        if (first { $_->getOption('#guessed-kde-project', 'module') } @modules) {
            my (undef, @expandedOptionModules) = _expandModuleSets($ctx, @optionModulesAndSets);
            _spliceOptionModules(\@modules, \@expandedOptionModules);

            debug ("--- re-spliced rc-file modules/sets into command line modules");
            debug ("   --- now ", scalar @modules, " modules present");
        }

        # At this point @modules has no more module sets, kde-projects or
        # otherwise.
        ksb::Module->setModuleSource('cmdline');
    }
    else {
        # Build everything in the rc-file, in the order specified.
        ($metadataModule, @modules) = _expandModuleSets($ctx, @optionModulesAndSets);

        debug ("--- Expanded rc-file module sets into ", scalar @modules, " modules.");
        debug ("   --- Metadata module needed? ", $metadataModule ? "Yes" : "No");

        if ($ctx->getOption('kde-languages')) {
            my $l10nModule = ksb::Module->new($ctx, 'l10n');
            $l10nModule->setScmType('l10n');
            $l10nModule->setBuildSystem($l10nModule->scm());

            debug ("--- Added l10n module to end of build");
            push @modules, $l10nModule;
        }

        ksb::Module->setModuleSource('config');
    }

    # Filter --resume-foo options. This might be a second pass, but that should
    # be OK since there's nothing different going on from the first pass in that
    # event.
    @modules = _applyModuleFilters($ctx, @modules);

    debug ("--- Applied all-modules --resume-foo pass, ", scalar @modules, " remain.");
    debug ("   --- ", (scalar grep { $_->isa("ksb::ModuleSet") } @modules), " are module sets (should be 0!).");

    # Apply kde-languages, by appending needed l10n modules to the end of the
    # build.
    @modules = _expandl10nModules($ctx, @modules);

    debug ("--- Expanded l10n modules. ", scalar @modules, " remain.");

    # Remove ignored modules and/or module-sets
    @modules = grep {
        not exists $ignore_list{$_->name()} && not exists $ignore_list{$_->moduleSet()->name()}
    } (@modules);

    debug ("--- Handled ignore lists. ", scalar @modules, " remain.");

    # If modules were on the command line then they are effectively forced to
    # process unless overridden by command line options as well. If phases
    # *were* overridden on the command line, then no update pass is required
    # (all modules already have correct phases)
    @modules = _updateModulePhases(@modules) unless $commandLineModules;

    debug ("--- Updated module phases. ", scalar @modules, " remain.");

    # Save our metadata module, if used.
    $self->{metadata_module} = $metadataModule;

    return @modules;
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
    my $endRE = qr/^end\s+$endWord/;

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
#  ctx - The <BuildContext> to update based on the configuration read.
#  filehandle - The I/O object to read from. Must handle _eof_ and _readline_
#  methods (e.g. <IO::Handle> subclass).
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
    my @module_list;
    my $rcfile = $ctx->rcFile();
    my ($option, $modulename, %readModules);

    my $fileReader = ksb::RecursiveFH->new();
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
        last;
    }

    my $using_default = 1;

    # Now read in module settings
    while ($_ = $fileReader->readLine())
    {
        s/#.*$//;          # Remove comments
        s/^\s*//;          # Remove leading whitespace
        next if (/^\s*$/); # Skip blank lines

        # Get modulename (has dash, dots, slashes, or letters/numbers)
        ($modulename) = /^module\s+([-\/\.\w]+)\s*$/;

        if (not $modulename)
        {
            my $moduleSetRE = qr/^module-set\s*([-\/\.\w]+)?\s*$/;
            ($modulename) = m/$moduleSetRE/;

            # modulename may be blank -- use the regex directly to match
            if (not /$moduleSetRE/) {
                error ("Invalid configuration file $rcfile!");
                error ("Expecting a start of module section at r[b[line $.].");
                die make_exception('Config', 'Ungrouped/Unknown option');
            }

            # A moduleset can give us more than one module to add.
            push @module_list, _parseModuleSetOptions($ctx, $fileReader, $modulename);
        }
        else {
            # Overwrite options set for existing modules.
            if (my @modules = grep { $_->name() eq $modulename } @module_list) {
                # We check for definedness as a module-set can exist but be
                # unnamed.
                if ($modules[0]->moduleSet()->isa('ksb::ModuleSet::Null')) {
                    warning ("Multiple module declarations for $modules[0]");
                }

                _parseModuleOptions($ctx, $fileReader, $modules[0]); # Don't re-add
            }
            else {
                push @module_list, _parseModuleOptions($ctx, $fileReader, $modulename);
            }
        }

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
#  $ctx - <BuildContext> in use for this script execution.
#  @modules - list of <Modules>, <ModuleSets> to be expanded.
#
# Returns:
#  $metadataModule - a <Module> to use if needed for kde-projects support, can be
#     undef if not actually required this run.
#  @modules - List of <Modules> with any module-sets expanded into <Modules>.
sub _expandModuleSets
{
    my ($ctx, @buildModuleList) = @_;

    my $filter = sub {
        my $moduleOrSetName = $_->name();

        # 'proj' module types can only come from command line -- we assume the
        # user is trying to build a module from the kde-projects repo without
        # first putting into rc-file.
        if ($_->isa('ksb::Module') && $_->scmType() ne 'proj') {
            return $_;
        }

        if ($_->isa('ksb::ModuleSet')) {
            return $_->convertToModules($ctx);
        }

        my $moduleSet = ksb::ModuleSet::KDEProjects->new($ctx, '<command line>');
        $moduleSet->setModulesToFind($_->name());
        $moduleSet->{options}->{'#guessed-kde-project'} = 1;

        debug ("--- Trying to find a home for $_");
        return $moduleSet->convertToModules($ctx);
    };

    my @moduleResults = map { &$filter } (@buildModuleList);
    my $metadataModule;

    if (first { $_->scmType() eq 'proj' } @moduleResults) {
        debug ("Introducing metadata module into the build");
        $metadataModule = ksb::ModuleSet::KDEProjects::getMetadataModule($ctx);
        assert_isa($metadataModule, 'ksb::Module');
    }

    return ($metadataModule, @moduleResults);
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

# Method: _processCmdlineArguments
#
# Processes the command line arguments, which are used to modify the given
# <BuildContext> and possibly return a list of <Modules>.
#
# This is a package method, should be called as $app->_processCmdlineArguments
#
# Phase:
#  initialization - Do not call <finish> from this function.
#
# Parameters:
#  ctx - BuildContext in use.
#  pendingOptions - hashref to hold parsed modules options to be applied later.
#    *Note* this must be done separately, it is not handled by this subroutine.
#  @options - The remainder of the arguments are treated as command line
#    arguments to process.
#
# Returns:
#  - List of <ksb::Modules> that represent modules specifically entered on the
#    command-line, _or_
#  - List of options to pass to a command named by the --run command line
#    option. (This is true if and only if the _ctx_ ends up with the
#    _#start-program_ option set).
sub _processCmdlineArguments
{
    my $self = shift;
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $pendingOptions = shift;
    my $phases = $ctx->phases();
    my @savedOptions = @_; # Used for --debug
    my @options = @_;
    my $arg;
    my $version = "kdesrc-build $SCRIPT_VERSION";
    my $author = <<DONE;
$version was written (mostly) by:
  Michael Pyne <mpyne\@kde.org>

Many people have contributed code, bugfixes, and documentation.

Please report bugs using the KDE Bugzilla, at http://bugs.kde.org/
DONE

    my @enteredModules;

    while ($_ = shift @options)
    {
        SWITCH: {
            /^(--version)$/      && do { print "$version\n"; exit; };
            /^--author$/         && do { print $author; exit; };
            /^(-h)|(--?help)$/   && do {
                print <<DONE;
$version
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

Copyright (c) 2003 - 2013 $author
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

    --<option>=          Any unrecognized options are added to the global
                         configuration, overriding any value that may exist.
    --<module>,<option>= Likewise, this allows you to override any module
                         specific option from the command line.

    --pretend (or -p)    Don't actually contact the source server, run make,
                         or create/delete files and directories.  Instead,
                         output what the script would have done.
    --refresh-build      Start the build from scratch.

    --help               You\'re reading it. :-)
    --version            Output the program version.

You can get more help by going online to http://kdesrc-build.kde.org/ to view
the online documentation.  If you have installed kdesrc-build you may also be
able to view the documentation using KHelpCenter or Konqueror at the URL
help:/kdesrc-build
DONE
                # We haven't done any locking... no need to finish()
                exit 0;
            };

            /^--install$/ && do {
                $self->{run_mode} = 'install';
                $phases->phases('install');

                last SWITCH;
            };

            /^--uninstall$/ && do {
                $self->{run_mode} = 'uninstall';
                $phases->phases('uninstall');

                last SWITCH;
            };

            /^--no-snapshots$/ && do {
                $ctx->setOption('#disable-snapshots', 1);
                last SWITCH;
            };

            /^--no-(src|svn)$/ && do {
                $phases->filterOutPhase('update');
                last SWITCH;
            };

            /^--no-install$/ && do {
                $phases->filterOutPhase('install');
                last SWITCH;
            };

            /^--no-tests$/ && do {
                # The "right thing" to do
                $phases->filterOutPhase('test');

                # What actually works at this point.
                $ctx->setOption('#run-tests', 0);
                last SWITCH;
            };

            /^--(force-build)|(no-build-when-unchanged)$/ && do {
                $ctx->setOption('#build-when-unchanged', 1);
                last SWITCH;
            };

            /^(-v)|(--verbose)$/ && do {
                $ctx->setOption('#debug-level', ksb::Debug::WHISPER);
                last SWITCH;
            };

            /^(-q)|(--quiet)$/ && do {
                $ctx->setOption('#debug-level', ksb::Debug::NOTE);
                last SWITCH;
            };

            /^--really-quiet$/ && do {
                $ctx->setOption('#debug-level', ksb::Debug::WARNING);
                last SWITCH;
            };

            /^--debug$/ && do {
                $ctx->setOption('#debug-level', ksb::Debug::DEBUG);
                debug ("Commandline was: ", join(', ', @savedOptions));
                last SWITCH;
            };

            /^--reconfigure$/ && do {
                $ctx->setOption('#reconfigure', 1);
                last SWITCH;
            };

            /^--color$/ && do {
                $ctx->setOption('#colorful-output', 1);
                last SWITCH;
            };

            /^--no-color$/ && do {
                $ctx->setOption('#colorful-output', 0);
                last SWITCH;
            };

            /^--no-build$/ && do {
                $phases->filterOutPhase('build');
                last SWITCH;
            };

            /^--async$/ && do {
                $ctx->setOption('#async', 1);
                last SWITCH;
            };

            /^--no-async$/ && do {
                $ctx->setOption('#async', 0);
                last SWITCH;
            };

            # Although equivalent to --no-build at this point, someday the
            # script may interpret the two differently, so get ready now.
            /^--(src|svn)-only$/ && do {      # Identically to --no-build
                $phases->phases('update');

                # We have an auto-switching function that we only want to run
                # if --src-only was passed to the command line, so we still
                # need to set a flag for it.
                $ctx->setOption('#allow-auto-repo-move', 1);
                last SWITCH;
            };

            # Don't run source updates or install
            /^--build-only$/ && do {
                $phases->phases('build');
                last SWITCH;
            };

            # Start up a program with the environment variables as
            # read from the config file.
            /^--run=?/ && do {
                my $program = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#start-program', $program);

                # Save remaining command line options to pass to the program.
                return @options;
            };

            /^--build-system-only$/ && do {
                $ctx->setOption('#build-system-only', 1);
                last SWITCH;
            };

            /^--rc-file=?/ && do {
                my $rcfile = _extractOptionValueRequired($_, \@options);
                $ctx->setRcFile($rcfile);

                last SWITCH;
            };

            /^--prefix=?/ && do {
                my $prefix = _extractOptionValueRequired($_, \@options);

                $ctx->setOption('#kdedir', $prefix);
                $ctx->setOption('#reconfigure', 1);

                last SWITCH;
            };

            /^--nice=?/ && do {
                my $niceness = _extractOptionValueRequired($_, \@options);

                $ctx->setOption('#niceness', $niceness);
                last SWITCH;
            };

            /^--ignore-modules$/ && do {
                # We need to keep _readConfigurationOptions() from adding these
                # modules to the build list, taken care of by ignore_list.  We
                # then need to remove the modules from the command line, taken
                # care of by the @options = () statement;
                my @innerOptions = ();
                foreach (@options)
                {
                    if (/^-/)
                    {
                        push @innerOptions, $_;
                    }
                    else
                    {
                        $ignore_list{$_} = 1;

                        # the pattern match doesn't work with $_, alias it.
                        my $module = $_;
                        @enteredModules = grep (!/^$module$/, @enteredModules);
                    }
                }
                @options = @innerOptions;

                last SWITCH;
            };

            /^(--dry-run)|(--pretend)|(-p)$/ && do {
                $ctx->setOption('#pretend', 1);
                # Simulate the build process too.
                $ctx->setOption('#build-when-unchanged', 1);
                last SWITCH;
            };

            /^--refresh-build$/ && do {
                $ctx->setOption('#refresh-build', 1);
                last SWITCH;
            };

            /^--delete-my-patches$/ && do {
                $ctx->setOption('#delete-my-patches', 1);
                last SWITCH;
            };

            /^--delete-my-settings$/ && do {
                $ctx->setOption('#delete-my-settings', 1);
                last SWITCH;
            };

            /^(--revision|-r)=?/ && do {
                my $revision = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#revision', $revision);

                last SWITCH;
            };

            /^--resume-from=?/ && do {
                $_ = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#resume-from', $_);

                last SWITCH;
            };

            /^--resume-after=?/ && do {
                $_ = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#resume-after', $_);

                last SWITCH;
            };

            /^--stop-after=?/ && do {
                $_ = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#stop-after', $_);

                last SWITCH;
            };

            /^--stop-before=?/ && do {
                $_ = _extractOptionValueRequired($_, \@options);
                $ctx->setOption('#stop-before', $_);

                last SWITCH;
            };

            /^--/ && do {
                # First let's see if they're trying to override a global option.
                my ($option) = /^--([-\w\d\/]+)/;
                my $value = _extractOptionValue($_, \@options);

                if ($ctx->hasOption($option))
                {
                    $ctx->setOption("#$option", $value);
                }
                else
                {
                    # Module specific option.  The module options haven't been
                    # read in, so we'll just have to assume that the module the
                    # user passes actually does exist.
                    my ($module, $option) = /^--([\w\/-]+),([-\w\d\/]+)/;

                    if (not $module)
                    {
                        print "Unknown option $_\n";
                        exit 8;
                    }

                    ${$pendingOptions}{$module}{"$option"} = $value;
                }

                last SWITCH;
            };

            /^-/ && do { print "WARNING: Unknown option $_\n"; last SWITCH; };

            # Strip trailing slashes.
            s/\/*$//;
            push @enteredModules, $_; # Reconstruct correct @options
        }
    }

    # Don't go async if only performing one phase.  It (should) work but why
    # risk it?
    if (scalar $phases->phases() == 1)
    {
        $ctx->setOption('#async', 0);
    }

    return map {
        my $module = ksb::Module->new($ctx, $_);
        # Following will be replaced by option modules if present in rc-file.
        $module->setScmType('proj');
        $module->setOption('#guessed-kde-project', 1);
        $module->phases()->phases($phases->phases());
        $module;
    } (@enteredModules);
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
