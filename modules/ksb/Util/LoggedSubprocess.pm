package ksb::Util::LoggedSubprocess 0.10;

use ksb;

=head1 SYNOPSIS

 my $cmd = ksb::Util::LoggedSubprocess->new
     ->module($module)           # required
     ->log_to($filename)         # required
     ->set_command($argRef)      # required
     ->chdir_to($builddir)       # optional
     ->announcer(sub ($mod) {    # optional
         note("g[$mod] starting update")
     })
     ;

 # optional, can have child output forwarded back to parent for processing
 $cmd->on(child_output => sub ($cmd, $line) {
     # called in parent!
     $log_command_callback->($line);
 });

 # once ready, call ->start to obtain a Mojo::Promise that
 # can be waited on or chained from, pending the result of
 # computation in a separate child process.
 my $promise = $cmd->start->then(sub ($exitcode) {
     $resultRef = {
         was_successful => $exitcode == 0,
         warnings       => $warnings,
         work_done      => $workDoneFlag,
     };
 });

=cut

=head1 DESCRIPTION

This is a subclass of L<Mojo::IOLoop::Subprocess> which integrates the functionality
of that class into kdesrc-build's logging and module tracking functions.

Like Mojolicious (and unlike most of the rest of kdesrc-build), this is a
'fluent' interface due to the number of adjustables vars that must be set,
including which module is being built, the log file to use, what directory to
build from, etc.

=cut

use Mojo::Base 'Mojo::IOLoop::Subprocess';
use Mojo::Promise;

use ksb::BuildException qw(croak_internal);
use ksb::Debug;
use ksb::Util qw(assert_isa disable_locale_message_translation p_chdir run_logged_command);

=head1 EVENTS

=head2 child_output

This event (see L<Mojo::EventEmitter>, which is a base class of this one) is
called whenever a line of output is produced in the child.  Use the base
class's C<on> method to subscribe to the event.

Any subscriptions to this event must be in place before C<start> is called, as
the child will not install a callback for this unless at least one subscriber
is in place.

=cut

=head1 ATTRIBUTES

These attributes are the configurable options that should be set before calling
C<start> to execute the desired command.  If called without arguments, returns
the existing value. See L<Mojo::Base> for more information on how attributes
work.

=head2 module

Sets the L<ksb::Module> that is being executed against.

=head2 log_to

Sets the base filename (without a .log extension) that should receive command output
in the log directory. This must be set even if child output will not be examined.

=head2 chdir_to

Sets the directory to run the command from just before execution in the child
process. Optional, if not set the directory will not be changed.  The directory is
never changed for the parent process!

=head2 set_command

Sets the command, and any arguments, to be run, as a reference to a list. E.g.

 $cmd->set_command(['make', '-j4']);

=head2 disable_translations

Optional. If set to a true value, causes the child process to attempt to
disable command localization by setting the "C" locale in the shell
environment. This can be needed for filtering command output but should be
avoided if possible otherwise.

=head2 announcer

Optional. Can be set to a sub that will be called with a single parameter (the
ksb::Module being built) in the child process just before the build starts.

You can use this to make an announcement just before the command is run since
there's no way to guarantee the timing in a longer build.

=cut

has 'module';
has 'log_to';
has 'chdir_to';
has 'set_command';
has 'disable_translations' => 0;
has 'announcer';

=head1 METHODS

=cut

=head2 start

Begins the execution, if possible.  Returns a L<Mojo::Promise> that resolves to
the exit code of the command being run.  0 indicates success, non-zero
indicates failure.

Exceptions may be thrown, which L<Mojo::Promise> will catch and convert into
a rejected promise. You must install a L<Mojo::Promise/"catch"> handler
on the promise to handle this condition.

=cut

sub start($self)
{
    assert_isa(my $module = $self->module, 'ksb::Module');
    croak_internal('Need to log somewhere')
        unless my $filename = $self->log_to;
    croak_internal('No command to run!')
        unless my $argRef = $self->set_command;
    croak_internal('Command list needs to be a listref!')
        unless ref $argRef eq 'ARRAY';

    my $dir_to_run_from = $self->chdir_to;
    my $announceSub     = $self->announcer;
    my @command = @{$argRef};

    if (pretending()) {
        local $" = "]', 'g[";
        pretend ("\tWould have run ('g[@command]')");
        return Mojo::Promise->resolve(0);
    }

    # Install callback handler to feed child output to parent if the parent has
    # a callback to filter through it.
    my $needsCallback = $self->has_subscribers('child_output');

    if ($needsCallback) {
        $self->on(progress => sub ($subp, $data) {
            my $line = $data->{child_data} // undef;
            if ($line) {
                $subp->emit(child_output => $line->[0]);
                return;
            }

            if (ref $data eq 'HASH') {
                die "unimplemented ", keys %$data;
            }
            die "unimplemented $data";
        });
    }

    my $succeeded = 0;

    return $self->run_p(sub {
        # in a child process
        p_chdir($dir_to_run_from)
            if $dir_to_run_from;
        disable_locale_message_translation()
            if $self->disable_translations();

        my $callback;
        if ($needsCallback) {
            $callback = sub ($line) {
                return unless defined $line;
                $self->_sendToParent($line);
            }
        }

        $announceSub->($module)
            if $announceSub;
        my $result = run_logged_command($module, $filename, $callback, @command);
        whisper("$command[0] complete, result $result");
        return $result;
    })->then(sub ($exitcode) {
        $succeeded = ($exitcode == 0);
        return $exitcode; # Don't change result, just pass it on
    })->finally(sub {
        # If an exception was thrown or we didn't succeed, set error log
        ksb::Util::_setErrorLogfile($module, "$filename.log")
            unless $succeeded;
    });
}

# Sends the given data to the parent process.  Our calling code and this
# package must share the same single channel (over the 'progress' event
# supported by Mojolicious).  Although we only support handling for the calling
# code (to send line-by-line output back to the parent), to support future
# expansion we send a hashref which we can add different keys to if we need to
# support other use cases.
sub _sendToParent($self, @data)
{
    $self->progress({
        child_data => [@data],
    });
}

1;
