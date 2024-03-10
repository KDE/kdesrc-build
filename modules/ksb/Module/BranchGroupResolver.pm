# SPDX-FileCopyrightText: 2013 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::Module::BranchGroupResolver;

# This provides an object that can be used to lookup the appropriate git branch
# to use for a given KDE project module and given desired logical branch group, using
# supplied JSON data (from repo-metadata's /dependencies directory).
#
# See also https://community.kde.org/Infrastructure/Project_Metadata

use ksb;

our $VERSION = '0.10';

use List::Util qw(first);

sub new
{
    my ($class, $jsonData) = @_;

    my $self = { };
    my @keys = qw/layers groups/;

    # Copy just the objects we want over.
    @{$self}{@keys} = @{$jsonData}{@keys};

    # For layers and groups, remove anything beginning with a '_' as that is
    # defined in the spec to be a comment of some sort.
    @{$self->{layers}} = grep { /^[^_]/ } @{$self->{layers}};

    # Deleting a hash slice. Sorry about the syntax.
    delete @{$self->{groups}}{grep { /^_/ } keys %{$self->{groups}}};

    # Extract wildcarded groups separately as they are handled separately
    # later. Note that the specific catch-all group '*' is itself handled
    # as a special case in findModuleBranch.

    $self->{wildcardedGroups} = {
        map { ($_, $self->{groups}->{$_}) }
        grep { substr($_,-1) eq '*' }
            keys %{$self->{groups}}
    };

    bless $self, $class;
    return $self;
}

# Returns the branch for the given logical group and module specifier. This
# function should not be called if the module specifier does not actually
# exist.
sub _findLogicalGroup
{
    my ($self, $module, $logicalGroup) = @_;

    # Using defined-or and still returning undef is on purpose, silences
    # warning about use of undefined value.
    return $self->{groups}->{$module}->{$logicalGroup} // undef;
}

sub findModuleBranch
{
    my ($self, $module, $logicalGroup) = @_;

    if (exists $self->{groups}->{$module}) {
        return $self->_findLogicalGroup($module, $logicalGroup);
    }

    my %catchAllGroupStats = map {
        # Map module search spec to prefix string that is required for a match
        $_ => substr($_, 0, -1)
    } keys %{$self->{wildcardedGroups}};

    # Sort longest required-prefix to the top... first match that is valid will
    # then also be the right match.
    my @orderedCandidates = sort {
        $catchAllGroupStats{$b} cmp $catchAllGroupStats{$a}
    } keys %catchAllGroupStats;

    my $match = first {
        substr($module, 0, length $catchAllGroupStats{$_}) eq
        $catchAllGroupStats{$_}
    } @orderedCandidates;

    if ($match) {
        return $self->_findLogicalGroup($match, $logicalGroup);
    }

    if (exists $self->{groups}->{'*'}) {
        return $self->_findLogicalGroup('*', $logicalGroup);
    }

    return;
}

1;
