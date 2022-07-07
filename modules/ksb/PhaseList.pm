package ksb::PhaseList;

# Handles the "phases" for kdesrc-build, e.g. a simple list of phases,
# and methods to add, clear, or filter out phases.

use ksb;

our $VERSION = '0.10';

use ksb::Util;

# Constructor. Passed in values are the initial phases in this set.
sub new
{
    my ($class, @args) = @_;
    push @args, qw(update build install)
        unless @args;
    return bless [@args], $class;
}

# Filters out the given phase from the current list of phases.
sub filterOutPhase
{
    my ($self, $phase) = @_;
    @{$self} = grep { $_ ne $phase } @{$self};
}

# Adds the requested phase to the list of phases to build.
sub addPhase
{
    my ($self, $phase) = @_;
    push @{$self}, $phase unless list_has([@{$self}], $phase);
}

# Returns true if the given phase name is present in this list.
sub has
{
    my ($self, $phase) = @_;
    return grep { $_ eq $phase } (@{$self});
}

# Get/sets number of phases depending on whether any are passed in.
sub phases
{
    my ($self, @args) = @_;
    @$self = @args if scalar @args;
    return @$self;
}

sub clear
{
    my $self = shift;
    splice @$self;
}

1;
