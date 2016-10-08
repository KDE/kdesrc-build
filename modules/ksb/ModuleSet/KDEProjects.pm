package ksb::ModuleSet::KDEProjects 0.20;

# Class: ModuleSet::KDEProjects
#
# This represents a collective grouping of modules that share common options,
# and are obtained via the kde-projects database at
# https://projects.kde.org/kde_projects.xml
#
# See also the parent class ModuleSet, from which most functionality is derived.
#
# The only changes here are to allow for expanding out module specifications
# (except for ignored modules), by using KDEXMLReader.
#
# See also: ModuleSet

use strict;
use warnings;
use 5.014;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

our @ISA = qw(ksb::ModuleSet);

use ksb::Module;
use ksb::Debug;
use ksb::KDEXMLReader 0.20;
use ksb::BuildContext 0.20;
use ksb::Util;

sub new
{
    my $self = ksb::ModuleSet::new(@_);
    $self->{projectsDataReader} = undef; # Will be filled in when we get fh
    return $self;
}

# Simple utility subroutine. See List::Util's perldoc
sub none_true
{
    ($_ && return 0) for @_;
    return 1;
}

# Function: getDependenciesModule
#
# A 'static' method that returns a <Module> that should be included
# first in the build context's module list.
#
# It will be configured to download required updates to the
# build-metadata required for kde-projects module support.
#
# It should be included exactly once in the build context, if there are
# one or more ksb::ModuleSet::KDEProjects present in the module list.
#
# Parameters:
#  ctx - the <ksb::BuildContext> for this script execution.
#
# Returns: The <Module> to added to the beginning of the update.
sub getDependenciesModule
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');

    my $metadataModule = ksb::Module->new($ctx, 'kde-build-metadata');

    # Hardcode the results instead of expanding out the project info
    $metadataModule->setOption('repository', 'kde:kde-build-metadata');
    $metadataModule->setOption('#xml-full-path', 'kde-build-metadata');
    $metadataModule->setOption('#branch:stable', 'master');
    $metadataModule->setScmType('metadata');
    $metadataModule->setOption('disable-snapshots', 1);
    $metadataModule->setOption('branch', 'master');

    my $moduleSet = ksb::ModuleSet::KDEProjects->new($ctx, '<kde-projects metadata>');
    $metadataModule->setModuleSet($moduleSet);

    # Ensure we only ever try to update source, not build.
    $metadataModule->phases()->phases('update');
    return $metadataModule;
}

# Function: _expandModuleCandidates
#
# A class method which goes through the modules in our search list (assumed to
# be found in the kde-projects XML database) and expands them into their
# equivalent git modules, and returns the fully expanded list. Non kde-projects
# modules cause an error, as do modules that do not exist at all within the
# database.
#
# *Note*: Before calling this function, the kde-projects database itself must
# have been downloaded first. Additionally a <Module> handling build support
# metadata must be included at the beginning of the module list, see
# getMetadataModule() for details.
#
# *Note*: Any modules that are part of a module-set requiring a specific
# branch, that don't have that branch, are also elided with only a debug
# message. This allows for building older branches of KDE even when newer
# modules are eventually put into the database.
#
# Parameters:
#  ctx - The <BuildContext> in use.
#  moduleSearchItem - The search description to expand in ksb::Modules. See
#  _projectPathMatchesWildcardSearch for a description of the syntax.
#
# Returns:
#  @modules - List of expanded git <Modules>.
#
# Throws:
#  Runtime - if the kde-projects database was required but couldn't be
#  downloaded or read.
#  Runtime - if the git-desired-protocol is unsupported.
#  Runtime - if an "assumed" kde-projects module was not actually one.
sub _expandModuleCandidates
{
    my $self = assert_isa(shift, 'ksb::ModuleSet::KDEProjects');
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $moduleSearchItem = shift;

    my $srcdir = $ctx->getSourceDir();

    my $xmlReader = $ctx->getProjectDataReader();
    my @allXmlResults = $xmlReader->getModulesForProject($moduleSearchItem);

    croak_runtime ("Unknown KDE project: $moduleSearchItem") unless @allXmlResults;

    # It's possible to match modules which are marked as inactive on
    # projects.kde.org, elide those.
    my @xmlResults = grep { $_->{'active'} ne 'false' } (@allXmlResults);

    # Bug 307694
    my $moduleSetBranch = $self->{'options'}->{'branch'} // '';
    if ($moduleSetBranch && !exists $self->{'options'}->{'tag'}) {
        debug ("Filtering kde-projects modules that don't have a $moduleSetBranch branch");
        @xmlResults = grep {
            list_has($_->{'branches'}, $moduleSetBranch)
        } (@xmlResults);
    }

    if (!@xmlResults) {
        warning (" y[b[*] Module y[$moduleSearchItem] is apparently XML-based, but contains no\n" .
                 "active modules to build!");
        my $count = scalar @allXmlResults;
        if ($count > 0) {
            warning ("\tAlthough no active modules are available, there were\n" .
                     "\t$count inactive modules. Perhaps the git modules are not ready?");
        }
    }

    # Setup module options.
    my @moduleList;
    my @ignoreList = $self->modulesToIgnore();

    foreach (@xmlResults) {
        my $result = $_;
        my $repo = $result->{'repo'};

        # Prefer kde: alias to normal clone URL.
        $repo =~ s(^git://anongit\.kde\.org/)(kde:);

        my $newModule = ksb::Module->new($ctx, $result->{'name'});
        $self->_initializeNewModule($newModule);
        $newModule->setOption('repository', $repo);
        $newModule->setOption('#xml-full-path', $result->{'fullName'});
        $newModule->setOption('#branch:stable', $result->{'branch:stable'});
        $newModule->setScmType('proj');

        my $tarball = $result->{'tarball'};
        $newModule->setOption('#snapshot-tarball', $tarball) if $tarball;

        if (none_true(
                map {
                    ksb::KDEXMLReader::_projectPathMatchesWildcardSearch(
                        $result->{'fullName'},
                        $_
                    )
                } (@ignoreList)))
        {
            push @moduleList, $newModule;
        }
        else {
            debug ("--- Ignoring matched active module $newModule in module set " .
                $self->name());
        }
    };

    return @moduleList;
}

# This function should be called after options are read and build metadata is
# available in order to convert this module set to a list of ksb::Module.
# Any modules ignored by this module set are excluded from the returned list.
# The modules returned have not been added to the build context.
sub convertToModules
{
    my ($self, $ctx) = @_;

    my @moduleList; # module names converted to ksb::Module objects.
    my %foundModules;

    # Setup default options for each module
    # Extraction of relevant XML modules will be handled immediately after
    # this phase of execution.
    for my $moduleItem ($self->modulesToFind()) {
        # We might have already grabbed the right module recursively.
        next if exists $foundModules{$moduleItem};

        # eval in case the XML processor throws an exception.
        undef $@;
        my @candidateModules = eval {
            $self->_expandModuleCandidates($ctx, $moduleItem);
        };

        if ($@) {
            die $@ if had_an_exception(); # Forward exception objects up
            croak_runtime("The XML for the KDE Project database could not be understood: $@");
        }

        my @moduleNames = map { $_->name() } @candidateModules;
        @foundModules{@moduleNames} = (1) x @moduleNames;
        push @moduleList, @candidateModules;
    }

    if (not scalar @moduleList) {
        warning ("No modules were defined for the module-set " . $self->name());
        warning ("You should use the g[b[use-modules] option to make the module-set useful.");
    }

    return @moduleList;
}

1;
