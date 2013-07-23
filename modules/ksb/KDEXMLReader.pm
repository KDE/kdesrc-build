package ksb::KDEXMLReader;

# Class: KDEXMLReader
#
# kde_projects.xml module-handling code.
# The core of this was graciously contributed by Allen Winter, and then
# touched-up and kdesrc-build'ed by myself -mpyne.
#
# In C++ terms this would be a singleton-class (as it uses package variables
# for everything due to XML::Parser limitations). So it is neither re-entrant
# nor thread-safe.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

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
sub new
{
    my $class = shift;
    my $inputHandle = shift;

    my $self = {
        inputHandle => $inputHandle,
    };

    return bless ($self, $class);
}

sub inputHandle
{
    my $self = shift;
    return $self->{inputHandle};
}

my @nameStack = ();        # Used to assign full names to modules.
my %xmlGroupingIds;        # XML tags which group repositories.
my @modules;               # Result list
my $curRepository;         # ref to hash table when we are in a repo
my $trackingReposFlag = 0; # >0 if we should be tracking for repo elements.
my $inRepo = 0;            # >0 if we are actually in a repo element.
my $searchProject = '';    # Project we're looking for.
my $desiredProtocol = '';  # URL protocol desired (normally 'git')

# Note on searchProject: A /-separated path is fine, in which case we look
# for the right-most part of the full path which matches all of searchProject.
# e.g. kde/kdebase/kde-runtime would be matched searchProject of either
# "kdebase/kde-runtime" or simply "kde-runtime".
sub getModulesForProject
{
    # These are the elements that can have <repo> under them AFAICS, and
    # participate in module naming. e.g. kde/calligra or
    # extragear/utils/kdesrc-build
    @xmlGroupingIds{qw/component module project/} = 1;

    my ($self, $proj, $protocol) = @_;

    # Sanity-check
    if ($proj eq '*' || !$proj) {
        die "You are trying to import all modules. This is unwise. Ensure " .
            "you do not have any use-module items with a bare '*'";
    }

    $searchProject = $proj;
    @modules = ();
    @nameStack = ();
    $inRepo = 0;
    $trackingReposFlag = 0;
    $curRepository = undef;
    $desiredProtocol = $protocol;

    my $parser = XML::Parser->new(
        Handlers =>
            {
                Start => \&xmlTagStart,
                End => \&xmlTagEnd,
                Char => \&xmlCharData,
            },
    );

    # Will die if the XML is not well-formed.
    $parser->parse($self->inputHandle());

    return @modules;
}

sub xmlTagStart
{
    my ($expat, $element, %attrs) = @_;

    # In order to ensure that repos which are recursively under this node are
    # actually handled, we increment this flag if it's already >0 (which means
    # we're actively tracking repos for some given module).
    # xmlTagEnd will then decrement the flag so we eventually stop tracking
    # repos once we've fully recursively handled the node we cared about.
    if ($trackingReposFlag > 0) {
        ++$trackingReposFlag;
    }

    if (exists $xmlGroupingIds{$element}) {
        push @nameStack, $attrs{'identifier'};

        # If we're not tracking something, see if we should be.
        if ($trackingReposFlag <= 0) {
            $trackingReposFlag =
                _projectPathMatchesWildcardSearch(
                    join('/', @nameStack), $searchProject
                )
                ? 1
                : 0;
        }
    }

    # This code used to check for direct descendants and filter them out.
    # Now there are better ways (kde-build-metadata/build-script-ignore and
    # the user can customize using ignore-modules), and this filter made it
    # more difficult to handle kde/kdelibs{,/nepomuk-{core,widgets}}, so leave
    # it out for now. See also bug 321667.
    if ($element eq 'repo' &&   # Found a repo
        $trackingReposFlag > 0) # When we were looking for one
    {
        # This flag is cleared by the <repo>-end handler, so this *should* be
        # logically impossible.
        die "We are already tracking a repository" if $inRepo > 0;

        $inRepo = 1;
        $curRepository = {
            'fullName' => join('/', @nameStack),
            'repo' => '',
            'name' => $nameStack[-1],
            'active' => 'false',
            'tarball' => '',
            'branch'   => '',
            'branches' => [ ],
            'branchtype' => '', # Either branch:stable or branch:trunk
        }; # Repo/Active/tarball to be added by char handler.
    }

    # Currently we only pull data while under a <repo> tag, so bail early if
    # we're not doing this to simplify later logic.
    return unless $inRepo;

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

sub xmlTagEnd
{
    my ($expat, $element) = @_;

    if (exists $xmlGroupingIds{$element}) {
        pop @nameStack;
    }

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
        $inRepo = 0;
        push @modules, $curRepository;
        $curRepository = undef;
    }

    # See xmlTagStart above for an explanation.
    --$trackingReposFlag;
}

sub xmlCharData
{
    my ($expat, $utf8Data) = @_;

    # The XML::Parser manpage makes it clear that the char handler can be
    # called consecutive times with data for the same tag, so we use the
    # append operator and then clear our flag in xmlTagEnd.
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
        # This logic is fairly long-winded but essentially just breaks
        # searchItem into its components and compares it item-for-item to
        # the end of our name stack.
        my @candidateArray = @nameStack[-(scalar @searchParts)..-1];
        die "candidate vs. search array mismatch" if $#candidateArray != $#searchParts;

        for (my $i = 0; $i < scalar @searchParts; ++$i) {
            if (($searchParts[$i] ne $candidateArray[$i]) &&
                ($searchParts[$i] ne '*'))
            {
                return;
            }
        }
    }
    else {
        return;
    }

    return 1;
}

1;
