package ksb::StatusMonitor 0.20;

# A class that records the result of executing the various build phases for
# each module, and can be subscribed to by interested recipients.

# This class is-a EventEmitter
use v5.22;
use warnings;

use Mojo::Base 'Mojo::EventEmitter';

use ksb::PhaseList 0.10;

sub new
{
    my $class = shift;

    return bless {
        # 'events' already taken...
        phase_events => [ ],
    }, $class;
}

# Creates a 'build plan' event based on the provided BuildContext, adds to the
# list of events, and announces to subscribers.
sub createBuildPlan
{
    my ($self, $ctx) = @_;

    my @phaseOrder = qw(
        update uninstall buildsystem build test install
    );
    my $moduleListref = $ctx->moduleList();

    my @modules = map {
        my $modPhases = $_->phases();
        my @phases = grep { $modPhases->has($_) } (@phaseOrder);

        # Implicit return, return keyword breaks out of map
        { name => $_->name(), phases => \@phases };
    } (@$moduleListref);

    my $result = {
        event => 'build_plan',
        build_plan => \@modules,
    };

    return $self->_announceEvent($result);
}

# Marks the a given build phase has begun.
sub markPhaseStart
{
    my ($self, $moduleName, $phase) = @_;

    my $result = {
        event => 'phase_started',
        phase_started => {
            module => $moduleName,
            phase  => $phase,
        },
    };

    return $self->_announceEvent($result);
}

# Marks progress made within a phase.  Try to avoid calling with redundant
# progresses though!
# The progress given should be in the range [0-1] (as a percentage).
sub markPhaseProgress
{
    my ($self, $moduleName, $phase, $progress) = @_;

    my $result = {
        event => 'phase_progress',
        phase_progress => {
            module   => $moduleName,
            phase    => $phase,
            progress => $progress,
        },
    };

    return $self->_announceEvent($result);
}

# Marks that a phase has completed.  Additional details can be passed
# in as a hash table.
sub markPhaseComplete
{
    my ($self, $moduleName, $phase, $resultDescription, %details) = @_;

    my $result = {
        event => 'phase_completed',
        phase_completed => {
            module => $moduleName,
            phase  => $phase,
            result => $resultDescription,
            %details,
        },
        # TODO: Add some useful stats
    };

    return $self->_announceEvent($result);
}

# Used for forward debugging logs to our subscribers
sub noteLogEvents
{
    my ($self, $moduleName, $phase, $eventsRef) = @_;

    my $result = {
        event => 'log_entries',
        log_entries => {
            module  => $moduleName,
            phase   => $phase,
            entries => $eventsRef,
        },
    };

    return $self->_announceEvent($result);
}

# Used to forward "post-build" messages, which are intended for any message
# that is important for the user to see but might be lost in the scrolling
# backlog. By calling these out the hope is that the U/I can ensure that the
# user is informed of important things that may still need done after the
# script ends.
sub notePostBuildMessage
{
    my ($self, $moduleName, $message) = @_;

    my $result = {
        event => 'new_postbuild_message',
        new_postbuild_message => {
            module  => $moduleName,
            message => $message,
        },
    };

    return $self->_announceEvent($result);
}

sub markBuildDone
{
    my ($self) = @_;

    # TODO: Add stats to the return value?
    my $result = {
        event => 'build_done',
        build_done => {
        },
    };

    return $self->_announceEvent($result);
}

sub events
{
    my $self = shift;
    return @{$self->{phase_events}};
}

sub _announceEvent
{
    my ($self, $event) = @_;

    push @{$self->{phase_events}}, $event;
    $self->emit('newEvent', $event);

    return $event;
}

1;

__END__

=head1 NAME

ksb::StatusMonitor -- Notes the success or failure of each phase of a module
build.

=head1 SYNOPSIS

  my $monitor = ksb::StatusMonitor->new;

  $monitor->on(newEvent => sub {
    my $resultRef = shift;
    # $resultRef->{event}  has the event type (always present).  Value is a key in this hashref
    # $resultRef->{$event} contains event detail (varies by event).
  });

  # separately, to inform the monitor of events...

  $monitor->createBuildPlan($ctx); # Let listeners know what to expect
  $monitor->markPhaseComplete($moduleName, $phase, 'success');
  # other phases...
  $monitor->markBuildDone();

=head1 DESCRIPTION

Right now there are six different events

=over

=item 1.

build_plan -- Used to announce the build that will be performed

=item 2.

phase_started -- Emitted for each individual phase once it starts

=item 3.

phase_progress -- Possibly emitted for an individual phase to track progress
of the phase to completion.

=item 4.

phase_completed -- Used for each individual completed phase as the build progresses

=item 5.

log_entries -- Used to permit important messages to the user to be forwarded
to the user interface during the build (e.g. that a git-stash has failed)

=item 6.

build_done -- Used when all phases are done (should be redundant but this way
you know for sure)

=item 7.

new_postbuild_message -- Used for messages that may get lost in the noise and should
be announced (or re-announced) to the user right as the script ends.

=back

=cut
