package ksb::PhaseList 0.20;

use ksb;

=head1 SYNOPSIS

 my $phases = ksb::PhaseList->new;
 $mod->createBuildSystem() if $phases->has('buildsystem');
 $phases->filterOutPhase('update') if $ctx->getOption('build-only');

=cut

=head1 DESCRIPTION

Handles the "phases" for kdesrc-build, e.g. a simple list of phases, and
methods to add, clear, or filter out phases.  Meant to be assigned to a
L<ksb::Module>.

=cut

=head1 METHODS

=head2 new

 my $phases1 = ksb::PhaseList->new; # default phases
 say "phases are " . join(', ', @{$phases1});

 my $phases2 = ksb::PhaseList->new(qw(update test install));

Constructs a new phase list, with the provided list of phases or
a default set of none are provided.

Returns a blessed listref.

=cut

sub new ($class, @args)
{
    push @args, qw(update build install)
        unless @args;
    return bless [@args], $class;
}

=head2 filterOutPhase

Instance method which removes the given phase from the list, if present.
Returns the instance.

=cut

sub filterOutPhase ($self, $phase)
{
    @{$self} = grep { $_ ne $phase } @{$self};
    return $self;
}

=head2 addPhase

Instance method which adds the given phase to the phase list at the end.

This is probably a misfeature; use L<splice|perlfunc/"splice"> to add the phase
in the right spot if it's not at the end.

=cut

sub addPhase ($self, $phase)
{
    push @{$self}, $phase
        unless $self->has($phase);
    return $self;
}

=head2 has

Instance method which returns true if the given phase is in the phase list.

=cut

sub has ($self, $phase)
{
    return grep { $_ eq $phase } (@{$self});
}

=head2 phases

Instance method. If provided a list, clears the existing list of phases and
resets them to the provided list. If not provided a list, returns the list of
phases without modifying the instance.

=cut

sub phases ($self, @args)
{
    @$self = @args
        if scalar @args;
    return @$self;
}

=head2 clear

Instance method that empties the phase list.

=cut

sub clear ($self)
{
    splice @$self;
    return $self;
}

1;
