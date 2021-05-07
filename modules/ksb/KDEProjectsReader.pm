package ksb::KDEProjectsReader 0.50;

# Class: KDEProjectsReader
#
# Enumerates and provides basic metadata of KDE projects, based on
# the YAML metadata included in sysadmin/repo-management.

use strict;
use warnings;
use 5.014;

use File::Find;

use ksb::BuildException;

sub _verifyYAMLModuleLoaded
{
# Load YAML-reading module if available without causing compile error if it
# isn't.  Note that YAML::Tiny and YAML do not work since some metadata files
# use features it doesn't support
    my @YAML_Opts = qw(Dump Load LoadFile);
    my @YAML_Mods = qw(YAML::XS YAML::Syck YAML::PP);
    my $success = 0;

    foreach my $mod (@YAML_Mods) {
        $success ||= eval "require $mod; $mod->import(\@YAML_Opts); 1;";
        last if $success;
    }

    if (!$success) {
        die "Unable to load one of " .
            join(', ', @YAML_Mods) .
            " modules, one of which is needed to handle KDE project data.";
    }
}

# Method: new
#
# Constructs a new KDEProjectsReader. This doesn't contradict any part of the class
# documentation which claims this class is a singleton however. This should be
# called as a method (e.g. KDEProjectsReader->new(...)).
#
# Parameters:
#  $projectMetadataModule - ksb::Module reference to the repo-metadata module.
sub new
{
    my $class = shift;
    my $projectMetadataModule = shift;

    _verifyYAMLModuleLoaded();

    my $self = {
        # Maps short names to repo info blocks
        repositories => { }
    };

    $self = bless ($self, $class);
    $self->_readProjectData($projectMetadataModule);

    return $self;
}

# The 'main' method for this class. Reads in *all* KDE projects and notes
# their details for later queries.
# Be careful, can throw exceptions.
sub _readProjectData
{
    my ($self, $projectMetadataModule) = @_;

    my $srcdir = $projectMetadataModule->fullpath('source');

    croak_runtime("No such source directory $srcdir!")
        unless -d $srcdir;

    my $files_searched = 0;

    File::Find::find({
        wanted => sub {
            if ($_ eq 'metadata.yaml') {
                $self->_readYAML($_);
                $files_searched++;
            }
        },
        follow => 1,
    }, "$srcdir/projects");

    croak_runtime("Failed to find KDE project entries from $srcdir!")
        unless $files_searched > 0;
}

sub _readYAML
{
    my ($self, $filename) = @_;

    my $proj_data = LoadFile($filename);

    #
    # these two are already 'covered' as special metadata modules, ignore them
    # TODO: Remove kde-build-metadata on or after 2021-01-01 as it is removed
    #
    if (($proj_data->{projectpath} eq 'kde-build-metadata' || $proj_data->{projectpath} eq 'repo-management'))
    {
        return;
    };

    my $repoPath = $proj_data->{repopath};
    my $repoName = $proj_data->{identifier} // $repoPath;

    my $curRepository = {
        'fullName' => $proj_data->{projectpath},
        'repo' => "kde:$repoPath.git",
        'name' => $repoName,
        'active' => !!$proj_data->{repoactive},
        'found_by' => 'direct', # can be changed in getModulesForProject
    };

    $self->{repositories}->{$repoName} = $curRepository;
}

# Note on $proj: A /-separated path is fine, in which case we look
# for the right-most part of the full path which matches all of searchProject.
# e.g. kde/kdebase/kde-runtime would be matched by a proj of either
# "kdebase/kde-runtime" or simply "kde-runtime".
sub getModulesForProject
{
    my ($self, $proj) = @_;

    my $repositoryRef = $self->{repositories};
    my @results;
    my $findResults = sub {
        my @matchList =
            grep {
                _projectPathMatchesWildcardSearch(
                    $repositoryRef->{$_}->{'fullName'}, $proj)
            } (sort keys %{$repositoryRef});

        if ($proj =~ m/\*/) {
            $repositoryRef->{$_}->{found_by} = 'wildcard' foreach @matchList;
        }

        push @results, @matchList;
    };

    # Wildcard matches happen as specified if asked for.
    # Non-wildcard matches have an implicit "$proj/*" search as well for
    # compatibility with previous use-modules
    # Project specifiers ending in .git are forced to be non-wildcarded.
    if ($proj !~ /\*/ && $proj !~ /\.git$/) {
        # We have to do a search to account for over-specified module names
        # like phonon/phonon
        $findResults->();

        # Now setup for a wildcard search to find things like kde/kdelibs/baloo
        # if just 'kdelibs' is asked for.
        $proj .= '/*';
    }

    $proj =~ s/\.git$//;

    # If still no wildcard and no '/' then we can use direct lookup by module
    # name.
    if ($proj !~ /\*/ && $proj !~ /\// && exists $repositoryRef->{$proj}) {
        push @results, $proj;
    }
    else {
        $findResults->();
    }

    return @{$repositoryRef}{@results};
}

# Utility subroutine, returns true if the given kde-project full path (e.g.
# kde/kdelibs/nepomuk-core) matches the given search item.
#
# The search item itself is based on path-components. Each path component in
# the search item must be present in the equivalent path component in the
# module's project path for a match. A '*' in a path component position for the
# search item matches any project path component.
#
# Finally, the search is pinned to search for a common suffix. E.g. a search
# item of 'kdelibs' would match a project path of 'kde/kdelibs' but not
# 'kde/kdelibs/nepomuk-core'. However 'kdelibs/*' would match
# 'kde/kdelibs/nepomuk-core'.
#
# First parameter is the full project path from the kde-projects database.
# Second parameter is the search item.
# Returns true if they match, false otherwise.
sub _projectPathMatchesWildcardSearch
{
    my ($projectPath, $searchItem) = @_;

    my @searchParts = split(m{/}, $searchItem);
    my @nameStack   = split(m{/}, $projectPath);

    if (scalar @nameStack >= scalar @searchParts) {
        my $sizeDifference = scalar @nameStack - scalar @searchParts;

        # We might have to loop if we somehow find the wrong start point for our search.
        # E.g. looking for a/b/* against a/a/b/c, we'd need to start with the second a.
        my $i = 0;
        while ($i <= $sizeDifference) {
            # Find our common prefix, then ensure the remainder matches item-for-item.
            for (; $i <= $sizeDifference; $i++) {
                last if $nameStack[$i] eq $searchParts[0];
            }

            return if $i > $sizeDifference; # Not enough room to find it now

            # At this point we have synched up nameStack to searchParts, ensure they
            # match item-for-item.
            my $found = 1;
            for (my $j = 0; $found && ($j < @searchParts); $j++) {
                return 1   if $searchParts[$j] eq '*'; # This always works
                $found = 0 if $searchParts[$j] ne $nameStack[$i + $j];
            }

            return 1 if $found; # We matched every item to the substring we found.
            $i++; # Try again
        }
    }

    return;
}

1;
