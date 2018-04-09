package ksb::StatusMonitor 0.10;

# A class that records the result of executing the various build phases for
# each module, and can be subscribed to by interested recipients.

# This class is-a EventEmitter
use Mojo::Base 'Mojo::EventEmitter';

use v5.014; # Require at least Perl 5.14

sub new
{
    my $class = shift;

    return bless {
        # 'events' already taken...
        phase_events => [ ],
    }, $class;
}

sub markPhaseComplete
{
    my ($self, $moduleName, $phase, $wasSuccessful) = @_;

    my $result = {
        module => $moduleName,
        phase  => $phase,
        # TODO Other result types?
        result => $wasSuccessful ? 'success' : 'error',
    };
    push @{$self->{phase_events}}, $result;

    $self->emit('phaseComplete', $result);
}

sub events
{
    my $self = shift;
    return @{$self->{phase_events}};
}

1;

__END__
ksb::StatusMonitor -- Notes the success or failure of each phase of a module
build.

  my $monitor = ksb::StatusMonitor->new;
  $monitor->on(phaseComplete => sub {
    my $resultRef = shift;
    # $resultRef->{module} has the name
    # $resultRef->{phase}  has the affected phase, like 'update', 'build'
    # $resultRef->{result} has a short textual description like 'success' or 'error'
  });
