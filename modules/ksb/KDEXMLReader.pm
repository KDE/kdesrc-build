package ksb::KDEXMLReader;

# kde_projects.xml module-handling code.
# The core of this was graciously contributed by Allen Winter, and then
# touched-up and kdesrc-build'ed by myself -mpyne.

use strict;
use warnings;
use v5.10;

use XML::Parser;

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
my $repoFound = 0;         # If we've already found the repo we need.
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

    my $result = $parser->parse($self->inputHandle());
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

        # If we're not tracking something, see if we should be. The logic is
        # fairly long-winded but essentially just breaks searchProject into
        # its components and compares it item-for-item to the end of our name
        # stack.
        if ($trackingReposFlag <= 0) {
            my @searchParts = split(m{/}, $searchProject);
            if (scalar @nameStack >= scalar @searchParts) {
                my @candidateArray = @nameStack[-(scalar @searchParts)..-1];
                die "candidate vs. search array mismatch" if $#candidateArray != $#searchParts;

                $trackingReposFlag = 1;
                for (my $i = 0; $i < scalar @searchParts; ++$i) {
                    if (($searchParts[$i] ne $candidateArray[$i]) &&
                        ($searchParts[$i] ne '*'))
                    {
                        $trackingReposFlag = 0;
                        last;
                    }
                }

                # Reset our found flag if we're looking for another repo
                $repoFound = 0 if $trackingReposFlag > 0;
            }
        }
    }

    # Checking that we haven't already found a repo helps us out in
    # situations where a supermodule has its own repo, -OR- you could build
    # it in submodules. We won't typically want to do both, so prefer
    # supermodules this way. (e.g. Calligra and its Krita submodules)
    if ($element eq 'repo' &&     # Found a repo
        $trackingReposFlag > 0 && # When we were looking for one
        ($trackingReposFlag <= $repoFound || $repoFound == 0))
            # (That isn't a direct child of an existing repo)
    {
        die "We are already tracking a repository" if $inRepo > 0;
        $inRepo = 1;
        $repoFound = $trackingReposFlag;
        $curRepository = {
            'fullName' => join('/', @nameStack),
            'repo' => '',
            'name' => $nameStack[-1],
            'active' => 'false',
            'tarball' => '',
            'branch:stable' => '',
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
    elsif ($element eq 'branch' && $attrs{'i18n'} && $attrs{'i18n'} eq 'stable') {
        $curRepository->{'needs'} = 'branch:stable';
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

1;
