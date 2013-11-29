package ksb::ModuleSet;

# Class: ModuleSet
#
# This represents a collective grouping of modules that share common options,
# and share a common repository (in this case, based on the git-repository-base
# option, but see also the more common ModuleSet::KDEProjects which is used for
# the special kde-projects repositories).
#
# This is parsed from module-set declarations in the rc-file.
#
# The major conceit here is several things:
#
# 1. A hash of options to set for each module read into this module set.
# 2. A list of module search declarations to be used to construct modules for
# this module set (in the case of kde-projects repository). For other
# repository types we can still consider it a 'search', but with the
# understanding that it's a 1:1 mapping to the 'found' module (which may not
# exist for real).
# 3. A list of module search declarations to *ignore* from this module set,
# using the same syntax as used to search for them in 2. This is only really
# useful at this point for kde-projects repository as everything else requires
# you to manually specify modules one-by-one (module-sets are only useful here
# for option grouping as per 1.).
# 4. A name, which must not be empty, although user-specified names cannot be
# assumed to be unique.
# 5. A ksb::PhaseList describing what phases of the build a module should
# participate in by default.
#
# See also: git-repository-base, ModuleSet::KDEProjects, use-modules

use strict;
use warnings;
use v5.10;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

our $VERSION = '0.10';

use ksb::Debug;
use ksb::Util;
use ksb::PhaseList;
use ksb::Module;

use Storable qw(dclone);

sub new
{
    my ($class, $ctx, $name) = @_;
    $name //= '';

    my $options = {
        name => $name,
        options => { },
        module_search_decls => [ ],
        module_ignore_decls => [ ],
        phase_list => ksb::PhaseList->new($ctx->phases()->phases()),
    };

    return bless $options, $class;
}

sub name
{
    my $self = shift;
    return $self->{name};
}

sub setName
{
    my ($self, $name) = @_;
    $self->{name} = $name;
    return;
}

# Returns a deep-copied hashref, not a hash.
sub options
{
    my $self = shift;
    return dclone($self->{options});
}

# Completely replaces stored options with the options given in the provided
# hashref.
sub setOptions
{
    my ($self, $hashref) = @_;
    $self->{options} = $hashref;
    return;
}

# Just returns a reference to the existing ksb::PhaseList, there's no way to
# replace this, though you can alter the underlying phases through the
# ksb::PhaseList object itself.
sub phases
{
    my $self = shift;
    return $self->{phase_list};
}

sub modulesToFind
{
    my $self = shift;
    return @{$self->{module_search_decls}};
}

sub setModulesToFind
{
    my ($self, @moduleDecls) = @_;
    $self->{module_search_decls} = [@moduleDecls];
    return;
}

# Same as modulesToFind, but strips away any path components to leave just
# module names. E.g. a "use-modules kde/kdelibs juk" would give (kdelibs, juk)
# as the result list.
sub moduleNamesToFind
{
    my $self = shift;
    return map { s{([^/]+)$}{$1}; $_ } ($self->modulesToFind());
}

sub modulesToIgnore
{
    my $self = shift;
    return @{$self->{module_ignore_decls}};
}

sub setModulesToIgnore
{
    my ($self, @moduleDecls) = @_;
    $self->{module_ignore_decls} = [@moduleDecls];
    return;
}

# Should be called for each new ksb::Module created in order to setup common
# module options.
sub _initializeNewModule
{
    my ($self, $newModule) = @_;

    $newModule->setModuleSet($self);
    $newModule->setScmType('git');
    $newModule->phases->phases($self->phases()->phases());

    # Dump all options into the existing ksb::Module's options.
    $newModule->setOption(%{$self->options()});
}

# This function should be called after options are read and build metadata is
# available in order to convert this module set to a list of ksb::Module.
# Any modules ignored by this module set are excluded from the returned list.
# The modules returned have not been added to the build context.
sub convertToModules
{
    my ($self, $ctx) = @_;

    my @moduleList; # module names converted to ksb::Module objects.
    my $optionsRef = $self->{options};

    # Note: This returns a hashref, not a string.
    my $repoSet = $ctx->getOption('git-repository-base');

    # Setup default options for each module
    # If we're in this method, we must be using the git-repository-base method
    # of setting up a module-set, so there is no 'search' or 'ignore' to
    # handle, just create ksb::Module and dump options into them.
    for my $moduleItem ($self->modulesToFind()) {
        my $moduleName = $moduleItem;

        $moduleName =~ s/\.git$//;

        my $newModule = ksb::Module->new($ctx, $moduleName);

        $self->_initializeNewModule($newModule);

        push @moduleList, $newModule;

        # Setup the only feature actually specific to a module-set, which is
        # the repository handling.
        my $selectedRepo = $repoSet->{$optionsRef->{'repository'}};
        $newModule->setOption('repository', $selectedRepo . $moduleItem);
    }

    if (not scalar $self->modulesToFind()) {
        warning ("No modules were defined for the module-set $self->name()");
        warning ("You should use the g[b[use-modules] option to make the module-set useful.");
    }

    return @moduleList;
}

1;
