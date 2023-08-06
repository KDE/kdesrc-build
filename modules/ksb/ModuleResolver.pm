package ksb::ModuleResolver 0.20;

# Handle proper resolution of module selectors, including option
# handling. See POD docs below for more details.

use ksb;

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;
use ksb::ModuleSet::KDEProjects;
use ksb::Module;

use List::Util qw(first);

# Public API

sub new
{
    my ($class, $ctx) = @_;

    my $self = {
        context                => $ctx,
        ignoredSelectors       => [ ],

        # Read in from rc-file
        inputModulesAndOptions => [ ],
        cmdlineOptions         => { },
        deferredOptions        => { },

        # Holds Modules defined in course of expanding module-sets
        definedModules         => { },

        # Holds use-module mentions with their source module-set
        referencedModules      => { },
    };

    return bless $self, $class;
}

sub setCmdlineOptions
{
    my ($self, $cmdlineOptionsRef) = @_;
    $self->{cmdlineOptions} = $cmdlineOptionsRef;
    return;
}

sub setDeferredOptions
{
    my ($self, $deferredOptionsRef) = @_;
    $self->{deferredOptions} = $deferredOptionsRef;
    return;
}

sub setIgnoredSelectors
{
    my ($self, $ignoredSelectorsRef) = @_;
    $self->{ignoredSelectors} = $ignoredSelectorsRef // [ ];
    return;
}

sub setInputModulesAndOptions
{
    my ($self, $modOptsRef) = @_;
    $self->{inputModulesAndOptions} = $modOptsRef;

    # Build lookup tables
    $self->{definedModules}    = { map { $_->name() => $_ } (@$modOptsRef) };
    $self->{referencedModules} = { _listReferencedModules(@{$modOptsRef}) };

    return;
}

# Applies cmdline and deferred options to the given modules or module-sets.
sub _applyOptions
{
    my ($self, @modules) = @_;
    my $cmdlineOptionsRef = $self->{cmdlineOptions};
    my $deferredOptionsRef = $self->{deferredOptions};

    foreach my $m (@modules) {
        my $name = $m->name();

        # Apply deferred options first
        $m->setOption(%{$deferredOptionsRef->{$name} // {}});

        # Most of time cmdline options will be empty
        if (%$cmdlineOptionsRef) {
            my %moduleCmdlineArgs = (
                # order is important here
                %{$cmdlineOptionsRef->{global} // {}},
                %{$cmdlineOptionsRef->{$name}  // {}},
            );

            # Remove any options that would interfere with cmdline args
            # to avoid any override behaviors in setOption()
            delete @{$m->{options}}{keys %moduleCmdlineArgs};

            # Reapply module-specific cmdline options
            $m->setOption(%moduleCmdlineArgs);
        }
    }

    return;
}

# Returns a hash table of all module names referenced in use-module
# declarations for any ModuleSets included within the input list.  Each entry
# in the hash table will map the referenced module name to the source
# ModuleSet.
sub _listReferencedModules
{
    my %setEntryLookupTable;
    my @results;

    for my $moduleSet (grep { $_->isa('ksb::ModuleSet') } (@_)) {
        @results = $moduleSet->moduleNamesToFind();

        # The parens in front of 'x' are semantically required for repetition!
        @setEntryLookupTable{@results} = ($moduleSet) x scalar @results;
    }

    return %setEntryLookupTable;
}

# Expands out a single module-set listed in referencedModules and places any
# ksb::Modules created as a result within the lookup table of Modules.
# Returns the list of created ksb::Modules
sub _expandSingleModuleSet
{
    my $self = shift;
    my $neededModuleSet = shift;

    my $selectedReason = 'partial-expansion:' . $neededModuleSet->name();
    my $lookupTableRef = $self->{definedModules};
    my $setEntryLookupTableRef = $self->{referencedModules};

    # expandModuleSets applies pending/cmdline options already.
    my @moduleResults = $self->expandModuleSets($neededModuleSet);
    if (!@moduleResults) {
        croak_runtime ("$neededModuleSet->name() expanded to an empty list of modules!");
    }

    $_->setOption('#selected-by', $selectedReason) foreach @moduleResults;

    # Copy entries into the lookup table, especially in case they're
    # from case 3
    @{$lookupTableRef}{map { $_->name() } @moduleResults} = @moduleResults;

    # Ensure Case 2 and Case 1 stays disjoint (our selectors should now be
    # in the lookup table if it uniquely matches a module at all).
    my @moduleSetReferents = grep {
        $setEntryLookupTableRef->{$_} == $neededModuleSet
    } (keys %$setEntryLookupTableRef);
    delete @{$setEntryLookupTableRef}{@moduleSetReferents};

    return @moduleResults;
}

# Determines the most appropriate module to return for a given selector.
# The selector may refer to a module or module-set, which means that the
# return value may be a list of modules.
sub _resolveSingleSelector
{
    my $self = shift;
    my $selector = shift;
    my $ctx = $self->{context};
    my $selectorName = $selector;
    my @results; # Will default to '$selector' if unset by end of sub

    # In the remainder of this code, lookupTableRef is basically handling
    # case 1, while setEntryLookupTableRef handles case 2. No ksb::Modules
    # are *both* case 1 and 2 at the same time, and a module-set can only
    # be case 1. We clean up and handle any case 3s (if any) at the end.

    my $lookupTableRef = $self->{definedModules};
    my $setEntryLookupTableRef = $self->{referencedModules};

    # Module selectors beginning with '+' force treatment as a kde-projects
    # module, which means they won't be matched here (we're only looking for
    # sets).
    my $forcedToKDEProject = substr($selectorName, 0, 1) eq '+';
    substr($selectorName, 0, 1, '') if $forcedToKDEProject;

    # Checks cmdline options only.  This is intended to make
    # --no-include-dependencies suppress the action of include-dependencies in
    # the config file so make the absence of the flag imply
    # include-dependencies for now.
    my $defIncluding = $ctx->getOption('include-dependencies');
    my $includingDeps =
        ($self->{cmdlineOptions}->{'global'}->{'include-dependencies'} // $defIncluding);

    # See resolveSelectorsIntoModules for what the 3 "cases" mentioned below are.

    # Case 2. We make these checks first since they may update %lookupTable
    if (exists $setEntryLookupTableRef->{$selectorName} &&
        !exists $lookupTableRef->{$selectorName})
    {
        my $neededModuleSet = $setEntryLookupTableRef->{$selectorName};
        my @moduleResults = $self->_expandSingleModuleSet($neededModuleSet);

        if (!$includingDeps) {
            $_->setOption('include-dependencies', 0) foreach @moduleResults;
        }

        # Now lookupTable should be updated with expanded modules.
        $selector = $lookupTableRef->{$selectorName} // undef;

        # If the selector doesn't match a name exactly it probably matches
        # a wildcard prefix. e.g. 'kdeedu' as a selector would pull in all kdeedu/*
        # modules, but kdeedu is not a module-name itself anymore. In this
        # case just return all the modules in the expanded list.
        if (!$selector) {
            push @results, @moduleResults;
        }
        else {
            $selector->setOption('#selected-by', 'name');
        }
    }
    # Case 1
    elsif (exists $lookupTableRef->{$selectorName}) {
        $selector = $lookupTableRef->{$selectorName};
        $selector->setOption('#selected-by', 'name')
            unless $selector->isa('ksb::ModuleSet');

        if (!$selector->isa('ksb::ModuleSet') && !$includingDeps) {
            # modules were manually selected on cmdline, so ignore
            # module-based include-dependencies, unless
            # include-dependencies also set on cmdline.
            $selector->setOption('#include-dependencies', 0);
        }
    }
    elsif (ref $selector && $selector->isa('ksb::Module')) {
        # We couldn't find anything better than what we were provided,
        # just use it.
        $selector->setOption('#selected-by', 'best-guess-after-full-search');
    }
    elsif ($forcedToKDEProject) {
        # Just assume it's a kde-projects module and expand away...
        $selector = ksb::ModuleSet::KDEProjects->new($ctx, '_cmdline');
        $selector->setModulesToFind($selectorName);
        $selector->setOption('#include-dependencies', $includingDeps);
    }
    else {
        # Case 3?
        $selector = ksb::Module->new($ctx, $selectorName);
        $selector->phases()->phases($ctx->phases()->phases());

        $selector->setScmType('proj');
        $selector->setOption('#guessed-kde-project', 1);
        $selector->setOption('#selected-by', 'initial-guess');
        $selector->setOption('#include-dependencies', $includingDeps);
    }

    push @results, $selector unless @results;

    return @results;
}

sub _expandAllUnexpandedModuleSets
{
    my $self = shift;

    my @unexpandedModuleSets = unique_items(values %{$self->{referencedModules}});
    $self->_expandSingleModuleSet($_) foreach @unexpandedModuleSets;
    return;
}

sub _resolveGuessedModules
{
    my $self = shift;
    my $ctx  = $self->{context};
    my @modules = @_;

    # We didn't necessarily fully expand all module-sets available in the
    # inputModulesAndOptions when we were resolving selectors.
    # Because of this we may need to go a step further and expand out all
    # remaining module-sets in rcFileModulesAndModuleSets if we have 'guess'
    # modules still left over (since they might be Case 3), and see if we can
    # then successfully match.

    if (!first { $_->getOption('#guessed-kde-project', 'module') } @modules) {
        return @modules;
    }

    my $lookupTableRef = $self->{definedModules};

    $self->_expandAllUnexpandedModuleSets();

    my @results;

    # We use foreach since we *want* to be able to replace the iterated variable
    # if we find an existing module.
    for my $guessedModule (@modules)
    {
        if (!$guessedModule->getOption('#guessed-kde-project', 'module')) {
            push @results, $guessedModule;
            next;
        }

        # If the module we want could be found from within our rc-file
        # module-sets (even implicitly), use it. Otherwise assume
        # kde-projects and evaluate now.
        if (exists $lookupTableRef->{$guessedModule->name()}) {
            $guessedModule = $lookupTableRef->{$guessedModule->name()};
            push @results, $guessedModule;
        }
        else {
            my $set = ksb::ModuleSet::KDEProjects->new($ctx, "guessed_from_cmdline");
            $set->setModulesToFind($guessedModule->name());

            my @setResults = $self->expandModuleSets($set);
            my $searchItem = $guessedModule->name();
            if (!@setResults) {
                croak_runtime ("$searchItem doesn't match any modules.");
            }

            my $foundModule = first { $_->name() eq $searchItem } @setResults;
            $guessedModule = $foundModule if $foundModule;

            push @results, @setResults;
        }
    }

    return @results;
}

# Resolves already-stored module selectors into ksb::Modules, based on
# the options, modules, and module-sets set.
#
# Returns a list of ksb::Modules in build order, with any module-sets fully
# expanded. The desired options will be set for each ksb::Module returned.
sub resolveSelectorsIntoModules
{
    my ($self, @selectors) = @_;
    my $ctx  = $self->{context};

    # Basically there are 3 types of selectors at this point:
    # 1. Directly named and defined modules or module-sets.
    # 2. Referenced (but undefined) modules. These are mentioned in a
    #    use-modules in a module set but not actually available as ksb::Module
    #    objects yet. But we know they will exist.
    # 3. Indirect modules. These are modules that do exist in the KDE project
    #    metadata, and will be pulled in once all module-sets are expanded
    #    (whether that's due to implicit wildcarding with use-modules, or due
    #    to dependency following). However we don't even know the names for
    #    these yet.

    # We have to be careful to maintain order of selectors throughout.
    my @outputList;
    for my $selector (@selectors) {
        next if list_has ($self->{ignoredSelectors}, $selector);
        push @outputList, $self->_resolveSingleSelector($selector);
    }

    my @modules = $self->expandModuleSets(@outputList);

    # If we have any 'guessed' modules then they had no obvious source in the
    # rc-file. But they might still be implicitly from one of our module-sets
    # (Case 3).
    # We want them to use ksb::Modules from the rc-file modules/module-sets
    # instead of our shell Modules, if possible.
    @modules = $self->_resolveGuessedModules(@modules);

    return @modules;
}

# Similar to resolveSelectorsIntoModules, except that in this case no
# 'guessing' for Modules is allowed; the requested module is returned if
# present, or undef otherwise. Also unlike resolveSelectorsIntoModules, no
# exceptions are thrown if the module is not present.
#
# The only major side-effect is that all known module-sets are expanded if
# necessary before resorting to returning undef.
sub resolveModuleIfPresent
{
    my ($self, $moduleName) = @_;

    if (%{$self->{referencedModules}}) {
        $self->_expandAllUnexpandedModuleSets();
    }

    # We may not already know about modules that can be found in kde-projects,
    # so double-check by resolving module name into a kde-projects module-set
    # selector (the + syntax) and then expanding out the module-set so generated.
    if (!defined $self->{definedModules}->{$moduleName}) {
        eval {
            $self->_expandSingleModuleSet(
                $self->_resolveSingleSelector("+$moduleName"));
        };
    }

    return $self->{definedModules}->{$moduleName} // undef;
}

# Replaces ModuleSets in the given list with their component Modules, and
# returns the new list.
sub expandModuleSets
{
    my $self      = shift;
    my $ctx       = $self->{context};
    my @buildModuleList = @_;

    my @returnList;
    foreach my $set (@buildModuleList) {
        my @results = $set;

        # If a module-set, need to update first so it can then apply its
        # settings to modules it creates, otherwise update Module directly.
        $self->_applyOptions($set);

        if ($set->isa('ksb::ModuleSet')) {
            @results = $set->convertToModules($ctx);
            $self->_applyOptions(@results);
        }

        push @returnList, @results;
    }

    return @returnList;
}

# Internal API

1;

__END__

=head1 ModuleResolver

A class that handles general management tasks associated with the
module build list, including option handling and resolution of module
selectors into actual modules.

=head2 METHODS

=over

=item new

Creates a new C<ModuleResolver>. You must pass the appropriate
C<BuildContext> Don't forget to call setCmdlineOptions(),
setIgnoredSelectors() and setInputModulesAndOptions().

 my $resolver = ModuleResolver->new($ctx);

=item setCmdlineOptions

Sets the options that should be applied to modules when they are created.
No special handling for global options is performed here (but see
ksb::OptionsBase::getOption and its friends).

You should pass in a hashref, where module-names are keys to values which
are themselves hashrefs of option-name => value pairs:

 $resolver->setCmdlineOptions(
    { mod1 => { 'cmake-options' => 'foo', ... },
      mod2 => { }
    })

=item setIgnoredSelectors

Declares all selectors that should be ignored by default in the process of
expanding module sets. Any modules matching these selectors would be elided
from any expanded module sets by default.

You should pass a listref of selectors.

=item setInputModulesAndOptions

Declares the list of all modules and module-sets known to the program,
along with their base options. Modules should be ksb::Module objects,
module-sets should be ksb::ModuleSet objects, no other types should be
present in the list.

You should pass a listref of Modules or ModuleSets (as appropriate).

=item resolveSelectorsIntoModules

Resolves the given list of module selectors into ksb::Module objects,
using the pending command-line options, ignore-selectors and available
modules/module-sets.

Selectors always choose an available ksb::Module or ksb::ModuleSet if
present (based on the name() of each Module or ModuleSet, including any
use-modules entries for ModuleSet objects). If a selector cannot be
directly found then ModuleSet objects may be expanded into their
constituent Module objects and the search performed again. If a selector
still cannot be found an exception is thrown.

Any embedded ModuleSets are expanded to Modules in the return value.

The list of selected Modules is returned, in the approximate order of the
input list (selectors for module-sets are expanded in arbitrary order).

If you are just looking for a Module that should already be present, see
resolveModuleIfPresent().

 my @modules = eval { $resolver->resolveSelectorsIntoModules('kdelibs', 'juk'); }

=item resolveModuleIfPresent

Similar to resolveSelectorsIntoModules(), except that no exceptions are
thrown if the module doesn't exist. Only a single module name is supported.

=item expandModuleSets

Converts any ksb::ModuleSet objects in the given list of Modules and
ModuleSets into their component ksb::Module objects (with proper options
set, and ignored modules not present). These component objects are spliced
into the list of module-type objects, replacing the ModuleSet they came
from.

The list of ksb::Module objects is then returned. The list passed in is
not actually modified in this process.

=back

=head2 IMPLEMENTATION

This module uses a multi-pass option resolving system, in accordance with
the way kdesrc-build handles options. Consider a simple kdesrc-buildrc:

 global
     cmake-options -DCMAKE_BUILD_TYPE=Debug
     ...
 end global

 module-set ms-foo
     cmake-options -DCMAKE_BUILD_TYPE=RelWithDebInfo
     repository kde-projects
     use-modules kde/kdemultimedia
     include-dependencies true
 end module-set

 options framework1
     set-env BUILD_DEBUG 1
 end options

 module taglib
     repository git://...
     branch 1.6
 end module

 options juk
     cxxflags -g3 -Og
     custom-build-command ninja
 end options

In this case we'd expect that a module like taglib ends up with its
C<cmake-options> derived from the global section directly, while all modules
included from module set C<ms-foo> use the C<cmake-options> defined in the
module-set.

At the same time we'd expect that juk has all the options listed in ms-foo, but
also the specific C<cxxflags> and C<custom-build-command> options shown,
I<no matter how> the juk module had been referenced during the build.

There are many ways to convince kdesrc-build to add a module into its build list:

=over

=item 1. Mention it directly on the command line.

=item 2. Include it in the kdesrc-buildrc file, either as a new C<module> block or
in a C<use-modules> of a C<module-set>.

=item 3. For KDE modules, mention a component of its project path in a
C<use-modules> declaration within a C<kde-projects>-based module set. E.g. the
"kde/kdemultimedia" entry above, which will pull in the juk module even though
"juk" is not named directly.

=item 4. For KDE modules, by being a dependency of a module included from a
C<module-set> where the C<include-dependencies> option is set to C<true>. This
wouldn't apply to juk, but might apply to modules such as phonon. Note that
"taglib" in this example would B<not> be a dependency of juk according to
kdesrc-build (although it is in reality), since taglib is not a KDE module.

=back

This mission of this class is to ensure that, no matter I<how> a module ended
up being selected by the user for the build list, that the same options are
registered into the module, the module uses the same build and scm types, is
defaulted to the right build phases, etc.

To do this, this class takes the read-in options, modules, and module sets from
the rc-file, the list of "selectors" requested by the user (via cmdline), any
changes to the options from the cmdline, and then takes pains to ensure that
any requested modules are returned via the appropriate module-set (and if no
module-set can source the module, via default options).

In doing so, the class must keep track of module sets, the modules included
into each module set, and modules that were mentioned somehow but not
already present in the known list of modules (or module sets).

Since module sets can cause modules to be defined that are not mentioned
anywhere within an rc-file, it may be required to completely expand all
module sets in order to verify that a referenced C<Module> is B<not>
already known.

=head2 OUTPUTS

From the perspective of calling code, the 'outputs' of this module are
lists of C<Module> objects, in the order they were selected (or mentioned
in the rc-file). See expandModuleSets() and resolveSelectorsIntoModules().

Each object so returned should already have the appropriate options
included (based on the cmdlineOptions member, which should be constructed
as the union of rc-file and cmdline options).

Note that dependency resolution is B<not> handled by this module, see
C<DependencyResolver> for that.

=cut
