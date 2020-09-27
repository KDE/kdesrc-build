package ksb::DebugOrderHints;

use warnings;
use v5.22;

# ksb::DebugOrderHints
#
# This module is motivated by the desire to help the user debug a kdesrc-build
# failure more easily. It provides support code to rank build failures on a per
# module from 'most' to 'least' interesting, as well as to sort the list of
# (all) failures by their respective rankings. This ranking is determined by
# trying to evaluate whether or not a given build failure fits a number of
# assumptions/heuristics. E.g.: a module which fails to build is likely to
# trigger build failures in other modules that depend on it (because of a
# missing dependency).
#

sub _getPhaseScore
{
    my $phase = shift;

    #
    # Assumption: build & install phases are interesting.
    # Install is particularly interesting because that should 'rarely' fail,
    # and so if it does there are probably underlying system issues at work.
    #
    # Assumption: 'test' is opt in and therefore the user has indicated a
    # special interest in that particular module?
    #
    # Assumption: source updates are likely not that interesting due to
    # e.g. transient network failure. But it might also indicate something
    # more serious such as an unclean git repository, causing scm commands
    # to bail.
    #

    return 4 if ($phase eq 'install');
    return 3 if ($phase eq 'test');
    return 2 if ($phase eq 'build');
    return 1 if ($phase eq 'update');
    return 0;
}

sub _compareDebugOrder
{
    my ($moduleGraph, $extraDebugInfo, $a, $b) = @_;
    my $nameA = $a->name();
    my $nameB = $b->name();

    #
    # Enforce a strict dependency ordering.
    # The case where both are true should never happen, since that would
    # amount to a cycle, and cycle detection is supposed to have been
    # performed beforehand.
    #
    # Assumption: if A depends on B, and B is broken then a failure to build
    # A is probably due to lacking a working B.
    #
    my $bDependsOnA = $moduleGraph->{$nameA}->{votes}->{$nameB} // 0;
    my $aDependsOnB = $moduleGraph->{$nameB}->{votes}->{$nameA} // 0;
    my $order = $bDependsOnA ? -1 : ($aDependsOnB ? 1 : 0);

    return $order if $order;

    #
    # TODO we could tag explicitly selected modules from command line?
    # If we do so, then the user is probably more interested in debugging
    # those first, rather than 'unrelated' noise from modules pulled in due
    # to possibly overly broad dependency declarations. In that case we
    # should sort explicitly tagged modules next highest, after dependency
    # ordering.
    #

    #
    # Assuming no dependency resolution, next favour possible root causes as
    # may be inferred from the dependency tree.
    #
    # Assumption: there may be certain 'popular' modules which rely on a
    # failed module. Those should probably not be considered as 'interesting'
    # as root cause failures in less popuplar dependency trees. This is
    # essentially a mitigation against noise introduced from raw 'popularity'
    # contests (see below).
    #
    my $isRootA = (scalar keys %{$moduleGraph->{$nameA}->{deps}}) == 0;
    my $isRootB = (scalar keys %{$moduleGraph->{$nameB}->{deps}}) == 0;

    return -1 if $isRootA && !$isRootB;
    return 1 if $isRootB && !$isRootA;

    #
    # Next sort by 'popularity': the item with the most votes (back edges) is
    # depended on the most.
    #
    # Assumption: it is probably a good idea to debug that one earlier.
    # This would point the user to fixing the most heavily used dependencies
    # first before investing time in more 'exotic' modules
    #
    my $voteA = scalar keys %{$moduleGraph->{$nameA}->{votes}};
    my $voteB = scalar keys %{$moduleGraph->{$nameB}->{votes}};
    my $votes = $voteB <=> $voteA;

    return $votes if $votes;

    #
    # Try and see if there is something 'interesting' that might e.g. indicate
    # issues with the system itself, preventing a successful build.
    #
    my $phaseA = _getPhaseScore($extraDebugInfo->{phases}->{$nameA} // '');
    my $phaseB = _getPhaseScore($extraDebugInfo->{phases}->{$nameB} // '');
    my $phase = $phaseB <=> $phaseA;

    return $phase if $phase;

    #
    # Assumption: persistently failing modules do not prompt the user
    # to act and therefore these are likely not that interesting.
    # Conversely *new* failures are.
    #
    # If we get this wrong the user will likely be on the case anyway:
    # someone does not need prodding if they have been working on it
    # for the past X builds or so already.
    #
    my $failCountA = $a->getPersistentOption('failure-count');
    my $failCountB = $b->getPersistentOption('failure-count');
    my $failCount = ($failCountA // 0) <=> ($failCountB // 0);

    return $failCount if $failCount;

    #
    # If there is no good reason to perfer one module over another,
    # simply sort by name to get a reproducible order.
    # That simplifies autotesting and/or reproducible builds.
    # (The items to sort are supplied as a hash so the order of keys is by
    # definition not guaranteed.)
    #
    my $name = ($nameA cmp $nameB);

    return $name;
}

sub sortFailuresInDebugOrder
{
    my ($moduleGraph, $extraDebugInfo, $failuresRef) = @_;
    my @failures = @{$failuresRef};

    my @prioritised = sort {
        _compareDebugOrder($moduleGraph, $extraDebugInfo, $a, $b);
    } (@failures);

    return @prioritised;
}

1;
