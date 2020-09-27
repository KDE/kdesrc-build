package ksb::DependencyResolver;

# Class: DependencyResolver
#
# This module handles resolving dependencies between modules. Each "module"
# from the perspective of this resolver is simply a module full name, as
# given by the KDE Project database.  (e.g. extragear/utils/kdesrc-build)

use warnings;
use v5.22;

our $VERSION = '0.20';

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;
use List::Util qw(first);

sub uniq
{
    my %seen;
    return grep { ++($seen{$_}) == 1 } @_;
}

# Constructor: new
#
# Constructs a new <DependencyResolver>.
#
# Parameters:
#
#   moduleFactoryRef - Reference to a sub that creates ksb::Modules from
#     kde-project module names. Used for ksb::Modules for which the user
#     requested recursive dependency inclusion.
#
# Synposis:
#
# > my $resolver = new DependencyResolver($modNewRef);
# > $resolver->readDependencyData(open my $fh, '<', 'file.txt');
# > $resolver->resolveDependencies(@modules);
sub new
{
    my $class = shift;
    my $moduleFactoryRef = shift;

    my $self = {
        # hash table mapping short module names (m) to a hashref key by branch
        # name, the value of which is yet another hashref (see
        # readDependencyData). Note that this assumes KDE git infrastructure
        # ensures that all full module names (e.g.
        # kde/workspace/plasma-workspace) map to a *unique* short name (e.g.
        # plasma-workspace) by stripping leading path components
        dependenciesOf  => { },

        # hash table mapping a wildcarded module name with no branch to a
        # listref of module:branch dependencies.
        catchAllDependencies => { },

        # reference to a sub that will properly create a ksb::Module from a
        # given kde-project module name. Used to support automatically adding
        # dependencies to a build.
        moduleFactoryRef => $moduleFactoryRef,
    };

    return bless $self, $class;
}

# Function: shortenModuleName
#
# Internal:
#
# This method returns the 'short' module name of kde-project full project paths.
# E.g. 'kde/kdelibs/foo' would be shortened to 'foo'.
#
# This is a static function, not an object method.
#
# Parameters:
#
#  path - A string holding the full module virtual path
#
# Returns:
#
#  The module name.
sub _shortenModuleName
{
    my $name = shift;
    $name =~ s{^.*/}{}; # Uses greedy capture by default
    return $name;
}

# Method: readDependencyData
#
# Reads in dependency data in a pseudo-Makefile format.
# See repo-metadata/dependencies/dependency-data.
#
# Parameters:
#  $self - The DependencyResolver object.
#  $fh   - Filehandle to read dependencies from (should already be open).
#
# Exceptions:
#  Can throw an exception on I/O errors or malformed dependencies.
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
        if ($sourceItem =~ m,\*$,) {
            warning ("\tIgnoring dependency on wildcard module grouping " .
                     "on line $. of repo-metadata/dependencies/dependency-data");
            next;
        }

        $dependentBranch ||= '*'; # If no branch, apply catch-all flag
        $sourceBranch ||= '*';

        # _shortenModuleName may remove negation marker so check now
        my $depKey = (index($sourceItem, '-') == 0) ? '-' : '+';
        $sourceItem =~ s/^-//; # remove negation marker if name already short

        # Source can never be a catch-all so we can shorten early. Also,
        # we *must* shorten early to avoid a dependency on a long path.
        $sourceItem = _shortenModuleName($sourceItem);

        # Handle catch-all dependent groupings
        if ($dependentItem =~ /\*$/) {
            $self->{catchAllDependencies}->{$dependentItem} //= [ ];
            push @{$self->{catchAllDependencies}->{$dependentItem}}, "$sourceItem:$sourceBranch";
            next;
        }

        $dependentItem = _shortenModuleName($dependentItem);

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

        push @{$dependenciesOfRef->{"$dependentItem:$dependentBranch"}->{$depKey}},
             "$sourceItem:$sourceBranch";
    }

    $self->_canonicalizeDependencies();
}

# Function: _canonicalizeDependencies
#
# Ensures that all stored dependencies are stored in a way that allows for
# reproducable dependency ordering (assuming the same dependency items and same
# selectors are used).
#
# Parameters: none
#
# Returns: none
sub _canonicalizeDependencies
{
    my $self = shift;
    my $dependenciesOfRef  = $self->{dependenciesOf};

    foreach my $dependenciesRef (values %{$dependenciesOfRef}) {
        @{$dependenciesRef->{'-'}} = sort @{$dependenciesRef->{'-'}};
        @{$dependenciesRef->{'+'}} = sort @{$dependenciesRef->{'+'}};
    }
}

sub _lookupDirectDependencies
{
    my $self = assert_isa(shift, 'ksb::DependencyResolver');
    my ($path, $branch) = @_;

    my $dependenciesOfRef = $self->{dependenciesOf};

    my @directDeps = ();
    my @exclusions = ();

    my $item = _shortenModuleName($path);
    my $moduleDepEntryRef = $dependenciesOfRef->{"$item:*"};

    if ($moduleDepEntryRef) {
        debug("handling dependencies for: $item without branch (*)");
        push @directDeps, @{$moduleDepEntryRef->{'+'}};
        push @exclusions, @{$moduleDepEntryRef->{'-'}};
    }

    if ($branch && $branch ne '*') {
        $moduleDepEntryRef = $dependenciesOfRef->{"$item:$branch"};
        if ($moduleDepEntryRef) {
            debug("handling dependencies for: $item with branch ($branch)");
            push @directDeps, @{$moduleDepEntryRef->{'+'}};
            push @exclusions, @{$moduleDepEntryRef->{'-'}};
        }
    }

    while (my ($catchAll, $deps) = each %{$self->{catchAllDependencies}}) {
        my $prefix = $catchAll;
        $prefix =~ s/\*$//;

        if (($path =~ /^$prefix/) || !$prefix) {
            push @directDeps, @{$deps};
        }
    }

    foreach my $exclusion (@exclusions) {
        # Remove only modules at the exact given branch as a dep.
        # However catch-alls can remove catch-alls.
        # But catch-alls cannot remove a specific branch, such exclusions have
        # to also be specific.
        @directDeps = grep { $_ ne $exclusion } (@directDeps);
    }

    my $result = {
        syntaxErrors => 0,
        trivialCycles => 0,
        dependencies => {}
    };

    for my $dep (@directDeps) {
        my ($depPath, $depBranch) = ($dep =~ m/^([^:]+):(.*)$/);
        if (!$depPath) {
            error("r[Invalid dependency declaration: b[$dep]]");
            ++($result->{syntaxErrors});
            next;
        }
        my $depItem = _shortenModuleName($depPath);
        if ($depItem eq $item) {
            debug("\tBreaking trivial cycle of b[$depItem] to itself");
            ++($result->{trivialCycles});
            next;
        }

        if ($result->{dependencies}->{$depItem}) {
            debug("\tSkipping duplicate direct dependency b[$depItem] of b[$item]");
        }
        else {
            $depBranch //= '';
            # work-around: wildcard branches are a don't care, not an actual
            # branch name/value
            $depBranch = undef if ($depBranch eq '' || $depBranch eq '*');
            $result->{dependencies}->{$depItem} = {
                item => $depItem,
                path => $depPath,
                branch => $depBranch
            };
        }
    }

    return $result;
}

sub _runDependencyVote
{
    my $moduleGraph = shift;

    for my $item (keys(%$moduleGraph)) {
        my @names = keys(%{$moduleGraph->{$item}->{allDeps}->{items}});
        for my $name (@names) {
            ++($moduleGraph->{$name}->{votes}->{$item});
        }
    }

    return $moduleGraph;
}

sub _detectDependencyCycle
{
    my ($moduleGraph, $depItem, $item) = @_;

    my $depModuleGraph = $moduleGraph->{$depItem};
    if ($depModuleGraph->{traces}->{status}) {
        if ($depModuleGraph->{traces}->{status} == 2) {
            debug("Already resolved $depItem -- skipping");
            return $depModuleGraph->{traces}->{result};
        }
        else {
            error("Found a dependency cycle at: $depItem while tracing $item");
            $depModuleGraph->{traces}->{result} = 1;
        }
    }
    else {
        $depModuleGraph->{traces}->{status} = 1;
        $depModuleGraph->{traces}->{result} = 0;

        my @names = keys(%{$depModuleGraph->{deps}});
        for my $name (@names) {
            if (_detectDependencyCycle($moduleGraph, $name, $item)) {
                $depModuleGraph->{traces}->{result} = 1;
            }
        }
    }

    $depModuleGraph->{traces}->{status} = 2;
    return $depModuleGraph->{traces}->{result};
}

sub _checkDependencyCycles
{
    my $moduleGraph = shift;

    my $errors = 0;

    for my $item (keys(%$moduleGraph)) {
        if(_detectDependencyCycle($moduleGraph, $item, $item)) {
            error("Somehow there is a circular dependency involving b[$item]! :(");
            error("Please file a bug against repo-metadata about this!");
            ++$errors;
        }
    }

    return $errors;
}

sub _copyUpDependenciesForModule
{
    my ($moduleGraph, $item) = @_;

    my $allDeps = $moduleGraph->{$item}->{allDeps};

    if($allDeps->{done}) {
        debug("\tAlready copied up dependencies for b[$item] -- skipping");
    }
    else {
        debug("\tCopying up dependencies and transitive dependencies for item: b[$item]");
        $allDeps->{items} = {};

        my @names = keys(%{$moduleGraph->{$item}->{deps}});
        for my $name (@names) {
            if ($allDeps->{items}->{$name}) {
                debug("\tAlready copied up (transitive) dependency on b[$name] for b[$item] -- skipping");
            }
            else {
                _copyUpDependenciesForModule($moduleGraph, $name);
                my @copied = keys(%{$moduleGraph->{$name}->{allDeps}->{items}});
                for my $copy (@copied) {
                    if ($allDeps->{items}->{$copy}) {
                        debug("\tAlready copied up (transitive) dependency on b[$copy] for b[$item] -- skipping");
                    }
                    else {
                        ++($allDeps->{items}->{$copy});
                    }
                }
                ++($allDeps->{items}->{$name});
            }
        }
        ++($allDeps->{done});
    }
}

sub _copyUpDependencies
{
    my $moduleGraph = shift;

    for my $item (keys(%$moduleGraph)) {
        _copyUpDependenciesForModule($moduleGraph, $item);
    }

    return $moduleGraph;
}

sub _detectBranchConflict
{
    my ($moduleGraph, $item, $branch) = @_;

    if ($branch) {
        my $subGraph = $moduleGraph->{$item};
        my $previouslySelectedBranch = $subGraph->{branch};

        return $previouslySelectedBranch if($previouslySelectedBranch && $previouslySelectedBranch ne $branch);
    }

    return undef;
}

sub _getDependencyPathOf
{
    my ($module, $item, $path) = @_;

    if ($module) {
        my $projectPath = $module->fullProjectPath();

        $projectPath = "third-party/$projectPath" if(!$module->isKDEProject());

        debug("\tUsing path: 'b[$projectPath]' for item: b[$item]");
        return $projectPath;
    }

    debug("\tGuessing path: 'b[$path]' for item: b[$item]");
    return $path;
}

sub _resolveDependenciesForModuleDescription
{
    my $self = assert_isa(shift, 'ksb::DependencyResolver');
    my ($moduleGraph, $moduleDesc) = @_;

    my $module = $moduleDesc->{module};
    if($module) {
        assert_isa($module, 'ksb::Module');
    }

    my $path = $moduleDesc->{path};
    my $item = $moduleDesc->{item};
    my $branch = $moduleDesc->{branch};
    my $prettyBranch = $branch ? "$branch" : "*";
    my $includeDependencies = $module
        ? $module->getOption('include-dependencies')
        : $moduleDesc->{includeDependencies};

    my $errors = {
        syntaxErrors => 0,
        trivialCycles => 0,
        branchErrors => 0
    };

    debug("Resolving dependencies for module: b[$item]");

    while (my ($depItem, $depInfo) = each %{$moduleGraph->{$item}->{deps}}) {
        my $depPath = $depInfo->{path};
        my $depBranch = $depInfo->{branch};

        my $prettyDepBranch = $depBranch ? "$depBranch" : "*";

        debug ("\tdep-resolv: b[$item:$prettyBranch] depends on b[$depItem:$prettyDepBranch]");

        my $depModuleGraph = $moduleGraph->{$depItem};

        if($depModuleGraph) {
            my $previouslySelectedBranch = _detectBranchConflict($moduleGraph, $depItem, $depBranch);
            if($previouslySelectedBranch) {
                error("r[Found a dependency conflict in branches ('b[$previouslySelectedBranch]' is not 'b[$prettyDepBranch]') for b[$depItem]! :(");
                ++($errors->{branchErrors});
            }
            else {
                if($depBranch) {
                    $depModuleGraph->{branch} = $depBranch;
                }
            }
        }
        else {
            my $depModule = $self->{moduleFactoryRef}($depItem);
            my $resolvedPath = _getDependencyPathOf($depModule, $depItem, $depPath);
            # May not exist, e.g. misspellings or 'virtual' dependencies like kf5umbrella.
            if(!$depModule) {
                debug("\tdep-resolve: Will not build virtual or undefined module: b[$depItem]\n");
            }

            my $depLookupResult = $self->_lookupDirectDependencies(
                $resolvedPath,
                $depBranch
            );

            $errors->{trivialCycles} += $depLookupResult->{trivialCycles};
            $errors->{syntaxErrors} += $depLookupResult->{syntaxErrors};

            $moduleGraph->{$depItem} = {
                votes => {},
                path => $resolvedPath,
                build => $depModule && $includeDependencies ? 1 : 0,
                branch => $depBranch,
                deps => $depLookupResult->{dependencies},
                allDeps => {},
                module => $depModule,
                traces => {}
            };

            my $depModuleDesc = {
                includeDependencies => $includeDependencies,
                module => $depModule,
                item => $depItem,
                path => $resolvedPath,
                branch => $depBranch
            };

            if (!$moduleGraph->{$depItem}->{build}) {
                debug (" y[b[*] $item depends on $depItem, but no module builds $depItem for this run.]");
            }

            if($depModule && $depBranch && (_getBranchOf($depModule) // '') ne "$depBranch") {
                my $wrongBranch = _getBranchOf($depModule) // '?';
                error(" r[b[*] $item needs $depItem:$prettyDepBranch, not $depItem:$wrongBranch]");
                ++($errors->{branchErrors});
            }

            debug("Resolving transitive dependencies for module: b[$item] (via: b[$depItem:$prettyDepBranch])");
            my $resolvErrors = $self->_resolveDependenciesForModuleDescription(
                $moduleGraph,
                $depModuleDesc
            );

            $errors->{branchErrors} += $resolvErrors->{branchErrors};
            $errors->{syntaxErrors} += $resolvErrors->{syntaxErrors};
            $errors->{trivialCycles} += $resolvErrors->{trivialCycles};
        }
    }

    return $errors;
}

sub resolveToModuleGraph
{
    my $self = assert_isa(shift, 'ksb::DependencyResolver');
    my @modules = @_;

    my %graph;
    my $moduleGraph = \%graph;

    my $result = {
        graph => $moduleGraph,
        errors => {
            branchErrors => 0,
            pathErrors => 0,
            trivialCycles => 0,
            syntaxErrors => 0,
            cycles => 0
        }
    };
    my $errors = $result->{errors};

    for my $module (@modules) {
        my $item = $module->name(); # _shortenModuleName($path);
        my $branch = _getBranchOf($module);
        my $path = _getDependencyPathOf($module, $item, '');

        if (!$path) {
            error("r[Unable to determine project/dependency path of module: $item]");
            ++($errors->{pathErrors});
            next;
        }

        if($moduleGraph->{$item}) {
            debug("Module pulled in previously through (transitive) dependencies: $item");
            my $previouslySelectedBranch = _detectBranchConflict($moduleGraph, $item, $branch);
            if($previouslySelectedBranch) {
                error("r[Found a dependency conflict in branches ('b[$previouslySelectedBranch]' is not 'b[$branch]') for b[$item]! :(");
                ++($errors->{branchErrors});
            }
            elsif ($branch) {
                $moduleGraph->{$item}->{branch} = $branch;
            }
            #
            # May have been pulled in via dependencies but not yet marked for
            # build. Do so now, since it is listed explicitly in @modules
            #
            $moduleGraph->{$item}->{build} = 1;
        }
        else {
            my $depLookupResult = $self->_lookupDirectDependencies(
                $path,
                $branch
            );

            $errors->{trivialCycles} += $depLookupResult->{trivialCycles};
            $errors->{syntaxErrors} += $depLookupResult->{syntaxErrors};

            $moduleGraph->{$item} = {
                votes => {},
                path => $path,
                build => 1,
                branch => $branch,
                module => $module,
                deps => $depLookupResult->{dependencies},
                allDeps => {},
                traces => {}
            };

            my $moduleDesc = {
                includeDependencies => $module->getOption('include-dependencies'),
                path => $path,
                item => $item,
                branch => $branch,
                module => $module
            };

            my $resolvErrors = $self->_resolveDependenciesForModuleDescription(
                $moduleGraph,
                $moduleDesc
            );

            $errors->{branchErrors} += $resolvErrors->{branchErrors};
            $errors->{syntaxErrors} += $resolvErrors->{syntaxErrors};
            $errors->{trivialCycles} += $resolvErrors->{trivialCycles};
        }
    }

    my $pathErrors = $errors->{pathErrors};
    if ($pathErrors) {
        error("Total of items which were not resolved due to path lookup failure: $pathErrors");
    }

    my $branchErrors = $errors->{branchErrors};
    if ($branchErrors) {
        error("Total of branch conflicts detected: $branchErrors");
    }

    my $syntaxErrors = $errors->{syntaxErrors};
    if ($syntaxErrors) {
        error("Total of encountered syntax errors: $syntaxErrors");
    }

    if ($syntaxErrors || $pathErrors || $branchErrors) {
        error("Unable to resolve dependency graph");

        $result->{graph} = undef;
        return $result;
    }

    my $trivialCycles = $errors->{trivialCycles};

    my $cycles = _checkDependencyCycles($moduleGraph);

    if ($cycles) {
        error("Total of items with at least one circular dependency detected: $errors");
        error("Unable to resolve dependency graph");

        $result->{cycles} = $cycles;
        $result->{graph} = undef;
        return $result;
    }
    else {
        $result->{graph} = _runDependencyVote(_copyUpDependencies($moduleGraph));
        return $result;
    }
}

sub hasErrors
{
    my $info = shift;

    my $cycles = $info->{cycles} // 0;
    my $pathErrors = $info->{pathErrors} // 0;
    my $branchErrors = $info->{branchErrors} // 0;
    my $syntaxErrors = $info->{syntaxErrors} // 0;

    return $cycles || $pathErrors || $branchErrors || $syntaxErrors;
}

sub _compareBuildOrder
{
    my ($moduleGraph, $a, $b) = @_;

    my $aVotes = $moduleGraph->{$a}->{votes};
    my $bVotes = $moduleGraph->{$b}->{votes};

    #
    # Enforce a strict dependency ordering.
    # The case where both are true should never happen, since that would
    # amount to a cycle, and cycle detection is supposed to have been
    # performed beforehand.
    #
    my $bDependsOnA = $aVotes->{$b} // 0;
    my $aDependsOnB = $bVotes->{$a} // 0;
    my $order = $bDependsOnA ? -1 : ($aDependsOnB ? 1 : 0);

    return $order if $order;

    #
    # Assuming no dependency relation, next sort by 'popularity':
    # the item with the most votes (back edges) is depended on the most
    # so it is probably a good idea to build that one earlier to help
    # maximise the duration of time for which builds can be run in parallel
    #
    my $votes = scalar keys %$bVotes <=> scalar keys %$aVotes;

    return $votes if $votes;

    #
    # If there is no good reason to perfer one module over another,
    # simply sort by the order contained within the configuration file (if
    # present), which would be setup as the rc-file is read.
    #
    my $aRcOrder = $moduleGraph->{$a}->{module}->{'#create-id'} // 0 ;
    my $bRcOrder = $moduleGraph->{$b}->{module}->{'#create-id'} // 0 ;
    my $configOrder = $aRcOrder <=> $bRcOrder;

    return $configOrder if $configOrder;

    #
    # If the rc-file is not present then sort by name to ensure a reproducible
    # build order that isn't influenced by randomization of the runtime.
    #
    return $a cmp $b;
}

sub sortModulesIntoBuildOrder
{
    my $moduleGraph = shift;

    my @resolved = keys(%{$moduleGraph});
    my @built = grep { $moduleGraph->{$_}->{build} && $moduleGraph->{$_}->{module} } (@resolved);

    my @prioritised = sort {
        _compareBuildOrder($moduleGraph, $a, $b);
    } (@built);

    my @modules = map { $moduleGraph->{$_}->{module} } (@prioritised);

    return @modules;
}

# Function: getBranchOf
#
# Internal:
#
# This function extracts the branch of the given Module by calling its
# scm object's branch-determining method. It also ensures that the branch
# returned was really intended to be a branch (as opposed to a detached HEAD);
# undef is returned when the desired commit is not a branch name, otherwise
# the user-requested branch name is returned.
sub _getBranchOf
{
    my $module = shift;

    my $scm = $module->scm();

    # when the module's SCM is not git,
    # assume the default "no particular" branch wildcard
    return undef unless $scm->isa('ksb::Updater::Git');

    my ($branch, $type) = $scm->_determinePreferredCheckoutSource($module);

    return ($type eq 'branch' ? $branch : undef);
}

1;
