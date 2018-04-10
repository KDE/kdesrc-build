package ksb::StatusMonitor 0.10;

# A class that records the result of executing the various build phases for
# each module, and can be subscribed to by interested recipients.

# This class is-a EventEmitter
use Mojo::Base 'Mojo::EventEmitter';

use ksb::PhaseList 0.10;

use v5.014; # Require at least Perl 5.14

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

sub markPhaseComplete
{
    my ($self, $moduleName, $phase, $wasSuccessful) = @_;

    my $result = {
        event => 'phase_completed',
        phase_completed => {
            module => $moduleName,
            phase  => $phase,
            result => $wasSuccessful ? 'success' : 'error',
        },
        # TODO: Add some useful stats
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

Right now there are three different events

=over

=item 1.

build_plan -- Used to announce the build that will be performed

=item 2.

phase_completed -- Used for each individual completed phase as the build progresses

=item 3.

build_done -- Used when all phases are done (should be redundant but this way
you know for sure)

=back

=cut
