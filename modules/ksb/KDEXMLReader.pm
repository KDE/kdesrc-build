package ksb::KDEXMLReader;

# Class: KDEXMLReader
#
# kde_projects.xml module-handling code.
# The core of this was graciously contributed by Allen Winter, and then
# touched-up and kdesrc-build'ed by myself -mpyne.
# (By late 2015 this is mostly mpyne's fault -mpyne).

use strict;
use warnings;
use 5.014;

our $VERSION = '0.20';

use XML::Parser;

# Method: new
#
# Constructs a new KDEXMLReader. This doesn't contradict any part of the class
# documentation which claims this class is a singleton however. This should be
# called as a method (e.g. KDEXMLReader->new(...)).
#
# Parameters:
#  $inputHandle - Ref to filehandle to read from. Must implement _readline_ and
#  _eof_.
#  $desiredProtocol - Normally 'git', but other protocols like 'http' can also
#   be preferred (e.g. for proxy compliance).
sub new
{
    my $class = shift;
    my $inputHandle = shift;
    my $desiredProtocol = shift;

    my $self = {
        # Maps short names to repo info blocks
        repositories => { },
    };

    $self = bless ($self, $class);
    $self->_readProjectData($inputHandle, $desiredProtocol);

    return $self;
}

# XML tags which group repositories.
my %xmlGroupingIds = (
    component => 1,
    module    => 1,
    project   => 1,
);

# The 'main' method for this class. Reads in *all* KDE projects and notes
# their details for later queries.
# Be careful, can throw exceptions.
sub _readProjectData
{
    my ($self, $inputHandle, $desiredProtocol) = @_;

    $desiredProtocol //= '';
    my $auxRef = {
        # Used to assign full names to modules.
        nameStackRef    => [],
        # >0 if we are actually in a repo element.
        inRepo          => 0,
        # ref to hash table entry for current XML element.
        curRepository   => undef,
        desiredProtocol => $desiredProtocol,
        repositoryRef   => $self->{repositories},
    };

    my $parser = XML::Parser->new(
        Handlers =>
            {
                Start => sub { _xmlTagStart($auxRef, @_); },
                End   => sub { _xmlTagEnd  ($auxRef, @_); },
                Char  => sub { _xmlCharData($auxRef, @_); },
            },
    );

    # Will die if the XML is not well-formed.
    $parser->parse($inputHandle);
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
        push @results, (
            grep {
                _projectPathMatchesWildcardSearch(
                    $repositoryRef->{$_}->{'fullName'}, $proj)
            } (keys %{$repositoryRef}));
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

sub _xmlTagStart
{
    my ($aux, $expat, $element, %attrs) = @_;

    my $nameStackRef = $aux->{nameStackRef};
    if (exists $xmlGroupingIds{$element}) {
        push @{$nameStackRef}, $attrs{'identifier'};
    }

    my $curRepository = $aux->{curRepository};
    my $inRepo = $aux->{inRepo};

    # This code used to check for direct descendants and filter them out.
    # Now there are better ways (kde-build-metadata/build-script-ignore and
    # the user can customize using ignore-modules), and this filter made it
    # more difficult to handle kde/kdelibs{,/nepomuk-{core,widgets}}, so leave
    # it out for now. See also bug 321667.
    if ($element eq 'repo')
    {
        # This flag is cleared by the <repo>-end handler, so this *should* be
        # logically impossible.
        die "We are already tracking a repository" if $inRepo > 0;

        $aux->{inRepo} = 1;
        my $name = ${$nameStackRef}[-1];
        $curRepository = {
            'fullName' => join('/', @{$nameStackRef}),
            'repo' => '',
            'name' => $name,
            'active' => 'false',
            'tarball' => '',
            'branch'   => '',
            'branches' => [ ],
            'branchtype' => '', # Either branch:stable or branch:trunk
        }; # Repo/Active/tarball to be added by char handler.

        $aux->{repositoryRef}->{$name} = $curRepository;
        $aux->{curRepository} = $curRepository;
    }

    # Currently we only pull data while under a <repo> tag, so bail early if
    # we're not doing this to simplify later logic.
    return unless $inRepo;

    my $desiredProtocol = $aux->{desiredProtocol};

    # Character data is integrated by the char handler. To avoid having it
    # dump all willy-nilly into our dict, we leave a flag for what the
    # resultant key should be.
    if ($element eq 'active') {
        $curRepository->{'needs'} = 'active';

        # Unset our default value since one is present in the XML
        $curRepository->{'active'} = '';
    }
    # For git repos we want to retain the repository data and any snapshot
    # tarballs available.
    elsif ($element eq 'url') {
        $curRepository->{'needs'} =
            #                     this proto       | needs this attr set
            $attrs{'protocol'} eq $desiredProtocol ? 'repo'    :
            $attrs{'protocol'} eq 'tarball'        ? 'tarball' : undef;
    }
    # i18n data gives us the defined stable and trunk branches.
    elsif ($element eq 'branch') {
        $curRepository->{'needs'} = 'branch';

        my $branchType = $attrs{'i18n'} // '';
        $curRepository->{'branchtype'} = "branch:$branchType" if $branchType;
    }
}

sub _xmlTagEnd
{
    my ($aux, $expat, $element) = @_;

    my $nameStackRef = $aux->{nameStackRef};
    if (exists $xmlGroupingIds{$element}) {
        pop @{$nameStackRef};
    }

    my $inRepo = $aux->{inRepo};
    my $curRepository = $aux->{curRepository};

    # If gathering data for char handler, stop now.
    if ($inRepo && defined $curRepository->{'needs'}) {
        delete $curRepository->{'needs'};
    }

    # Save all branches encountered, mark which ones are 'stable' and 'trunk'
    # for i18n purposes, as this keys into use-stable-kde handling.
    if ($element eq 'branch') {
        my $branch = $curRepository->{'branch'};
        push @{$curRepository->{'branches'}}, $branch;
        $curRepository->{'branch'} = '';

        my $branchType = $curRepository->{'branchtype'};
        $curRepository->{$branchType} = $branch if $branchType;
        $curRepository->{'branchtype'} = '';
    }

    if ($element eq 'repo' && $inRepo) {
        $aux->{inRepo} = 0;
        $aux->{curRepository} = undef;
    }
}

sub _xmlCharData
{
    my ($aux, $expat, $utf8Data) = @_;
    my $curRepository = $aux->{curRepository};

    # The XML::Parser manpage makes it clear that the char handler can be
    # called consecutive times with data for the same tag, so we use the
    # append operator and then clear our flag in _xmlTagEnd.
    if ($curRepository && defined $curRepository->{'needs'}) {
        $curRepository->{$curRepository->{'needs'}} .= $utf8Data;
    }
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
