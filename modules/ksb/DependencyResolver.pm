package ksb::DependencyResolver;

# This module handles resolving dependencies between modules. Each "module"
# from the perspective of this resolver is simply a module full name, as
# given by the KDE Project database.  (e.g. extragear/utils/kdesrc-build)

use strict;
use warnings;
use v5.10;

our $VERSION = '0.20';

use ksb::Debug;
use ksb::Util;
use List::Util qw(first);

sub new
{
    my $class = shift;

    my $self = {
        # hash table mapping full module names (m) to a hashref key by branch
        # name, the value of which is yet another hashref (see readDependencyData)
        dependenciesOf  => { },
    };

    return bless $self, $class;
}

# Reads in dependency data in a psuedo-Makefile format.
# See kde-build-metadata/dependency-data.
#
# Object method.
# First parameter is the filehandle to read from.
sub readDependencyData
{
    my $self = assert_isa(shift, 'ksb::DependencyResolver');
    my $fh = shift;

    my $dependenciesOfRef  = $self->{dependenciesOf};
    my $dependencyAtom =
        qr/
        ^\s*        # Clear leading whitespace
        ([^\[:\s]+) # (1) Capture anything not a [, :, or whitespace (dependent item)
        \s*         # Clear whitespace we didn't capture
        (?:\[       # Open a non-capture group...
            ([^\]:\s]+) # (2) Capture branch name without brackets
        ])?+        # Close group, make optional, no backtracking
        \s*         # Clear whitespace we didn't capture
        :
        \s*
        ([^\s\[]+)  # (3) Capture all non-whitespace (source item)
        (?:\s*\[     # Open a non-capture group...
            ([^\]\s]+) # (4) Capture branch name without brackets
        ])?+        # Close group, make optional, no backtracking
        \s*$        # Ensure no trailing cruft. Any whitespace should end line
        /x;         # /x Enables extended whitespace mode

    while(my $line = <$fh>) {
        # Strip comments, skip empty lines.
        $line =~ s{#.*$}{};
        next if $line =~ /^\s*$/;

        if ($line !~ $dependencyAtom) {
            croak_internal("Invalid line $line when reading dependency data.");
        }

        my ($dependentItem, $dependentBranch,
            $sourceItem,    $sourceBranch) = $line =~ $dependencyAtom;

        # Ignore "catch-all" dependencies where the source is the catch-all
        next if $sourceItem =~ m,\*$,;

        # Ignore deps on Qt, since we allow system Qt.
        next if $sourceItem =~ /^\s*Qt/ || $dependentItem =~ /^\s*Qt/;

        $dependentBranch ||= '*'; # If no branch, apply catch-all flag
        $sourceBranch ||= '*';

        # Initialize with hashref if not already defined. The hashref will hold
        #     - => [ ] (list of explicit *NON* dependencies of item:$branch),
        #     + => [ ] (list of dependencies of item:$branch)
        #
        # Each dependency item is tracked at the module:branch level, and there
        # is always at least an entry for module:*, where '*' means branch
        # is unspecified and should only be used to add dependencies, never
        # take them away.
        #
        # Finally, all (non-)dependencies in a list are also of the form
        # fullname:branch, where "*" is a valid branch.
        $dependenciesOfRef->{"$dependentItem:*"} //= {
            '-' => [ ],
            '+' => [ ],
        };

        # Create actual branch entry if not present
        $dependenciesOfRef->{"$dependentItem:$dependentBranch"} //= {
            '-' => [ ],
            '+' => [ ],
        };

        my $depKey = (index($sourceItem, '-') == 0) ? '-' : '+';
        $sourceItem =~ s/^-//;

        push @{$dependenciesOfRef->{"$dependentItem:$dependentBranch"}->{$depKey}},
             "$sourceItem:$sourceBranch";
    }
}

# Internal.
# This method adds any full module names as dependencies of any module that
# begins with that full module name. E.g. kde/kdelibs/foo automatically
# depends on kde/kdelibs if both are present in the build.
#
# Static method.
# First parameter: Reference to a hash of parameters.
# Return: Nothing.
sub _addInherentDependencies
{
    my $optionsRef = shift;
    my $dependenciesOfRef   = $optionsRef->{dependenciesOf};
    my $modulesFromNameRef  = $optionsRef->{modulesFromName};

    # It's not good enough to just sort modules and compare one to its
    # successor. Consider kde/foo, kde/foobar, kde/foo/a. The dependency
    # here would be missed that way. Instead we strip off the last path
    # component and see if that matches an existing module name.
    for my $testModule (keys %{$modulesFromNameRef}) {
        my $candidateBaseModule = $testModule;

        # Remove trailing component, bail if unable to do so.
        next unless $candidateBaseModule =~ s(/[^/]+$)();

        if ($candidateBaseModule &&
            exists $modulesFromNameRef->{$candidateBaseModule})
        {
            # Add candidateBaseModule as dependency of testModule.
            $dependenciesOfRef->{"$testModule:*"} //= {
                '-' => [ ],
                '+' => [ ],
            };

            my $moduleDepsRef = $dependenciesOfRef->{"$testModule:*"}->{'+'};
            if (!first { $_ eq $candidateBaseModule } @{$moduleDepsRef}) {
                debug ("dep-resolv: Adding $testModule as dependency of $candidateBaseModule");
                push @{$moduleDepsRef}, "$candidateBaseModule:*";
            }
        }
    }
}

# Finds the direct dependencies of the given module at a given branch.
sub _directDependenciesOf
{
    my ($dependenciesOfRef, $module, $branch) = @_;

    my $moduleDepEntryRef = $dependenciesOfRef->{"$module:*"};
    my @directDeps;
    my @exclusions;

    return unless $moduleDepEntryRef;

    push @directDeps, @{$moduleDepEntryRef->{'+'}};

    $moduleDepEntryRef = $dependenciesOfRef->{"$module:$branch"};
    if ($moduleDepEntryRef) {
        push @directDeps, @{$moduleDepEntryRef->{'+'}};
        push @exclusions, @{$moduleDepEntryRef->{'-'}};
    }

    foreach my $exclusion (@exclusions) {
        my ($moduleName, $branchName) = $exclusion =~ m,^([^:]+):(.*)$,;

        # Remove only modules at the exact given branch as a dep.
        # We do this even for "catch-alls", so that specific branches are
        # not removed by a "catch-all" exclusion.
        @directDeps = grep { $_ ne $exclusion } (@directDeps);
    }

    return @directDeps;
}

# Internal.
# This method is used to topographically sort dependency data. It accepts
# a ksb::Module, ensures that any KDE Projects it depends on are already on the
# build list, and then adds the ksb::Module to the build list (whether it is
# a KDE Project or not, to preserve ordering).
#
# Static method.
# First parameter: Reference to a hash of parameters.
# Second parameter: ksb::Module to "visit". Does not have to be a KDE Project.
# Return: Nothing.
sub _visitModuleAndDependencies
{
    my ($optionsRef, $module) = @_;
    assert_isa($module, 'ksb::Module');

    my $visitedItemsRef     = $optionsRef->{visitedItems};
    my $properBuildOrderRef = $optionsRef->{properBuildOrder};
    my $dependenciesOfRef   = $optionsRef->{dependenciesOf};
    my $modulesFromNameRef  = $optionsRef->{modulesFromName};

    my $item = $module->getOption('#xml-full-path');

    if (!$item) {
        push @{$properBuildOrderRef}, $module;
        return;
    }

    debug ("dep-resolv: Visiting $item");

    $visitedItemsRef->{$item} //= 0;

    # This module may have already been added to build.
    return if $visitedItemsRef->{$item} == 1;

    # But if the value is 2 that means we've detected a cycle.
    if ($visitedItemsRef->{$item} > 1) {
        croak_internal("Somehow there is a dependency cycle involving $item! :(");
    }

    $visitedItemsRef->{$item} = 2; # Mark as currently-visiting for cycle detection.

    my $branch = $module->scm()->getBranch();
    for my $subItem (_directDependenciesOf($dependenciesOfRef, $item, $branch)) {
        my ($subItemName, $subItemBranch) = ($subItem =~ m/^([^:]+):(.*)$/);
        croak_internal("Invalid dependency item: $subItem") if !$subItemName;

        debug ("\tdep-resolv: $item:$branch depends on $subItem");

        my $subModule = $modulesFromNameRef->{$subItemName};
        if (!$subModule) {
            whisper (" y[b[*] $module:$branch depends on $subItem, but no module builds $subItem for this run.");
            next;
        }

        if ($subItemBranch ne '*' && $subModule->scm()->getBranch() ne $subItemBranch) {
            my $wrongBranch = $subModule->scm()->getBranch();
            error (" r[b[*] $module:$branch needs $subItem, not $subItemName:$wrongBranch");
        }

        _visitModuleAndDependencies($optionsRef, $subModule);
    }

    $visitedItemsRef->{$item} = 1; # Mark as done visiting.
    push @{$properBuildOrderRef}, $module;
    return;
}

# This method takes a list of Modules (real ksb::Module objects, not just module
# names).
#
# These modules have their dependencies resolved, and a new list of Modules
# is returned, containing the proper build order for the module given.
#
# Only "KDE Project" modules can be re-ordered or otherwise affect the
# build so this currently won't affect Subversion modules or "plain Git"
# modules.
#
# The dependency data must have been read in first (readDependencyData).
#
# Object method
# Parameters: Modules to evaluate, in suggested build order.
# Return: Modules to build, with any KDE Project modules in a valid
# ordering based on the currently-read dependency data.
sub resolveDependencies
{
    my $self = assert_isa(shift, 'ksb::DependencyResolver');
    my @modules = @_;

    my $optionsRef = {
        visitedItems => { },
        properBuildOrder => [ ],
        dependenciesOf => $self->{dependenciesOf},

        # will map names back to their Modules
        modulesFromName => {
            map { $_->getOption('#xml-full-path') => $_ } @modules
        },
    };

    # Adds things like kde/kdelibs/foo to automatically depend on
    # kde/kdelibs if both are present in the build.
    _addInherentDependencies($optionsRef);

    for my $module (@modules) {
        _visitModuleAndDependencies($optionsRef, $module);
    }

    return @{$optionsRef->{properBuildOrder}};
}

1;
