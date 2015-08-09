package ksb::StatusView 0.10;

# Helper used to handle a generic 'progress update' status for the module
# build, update, install, etc. processes.
#
# Currently supports TTY output only but it's not impossible to visualize
# extending this to a GUI or even web server as options.

use strict;
use warnings;
use 5.014;

use ksb::Debug;

use IO::Handle;

sub new
{
    my $class = shift;
    my $defaultOpts = {
        cur_progress   => -1,
        progress_total => -1,
        status         => '',
    };

    # Must bless a hash ref since subclasses expect it.
    return bless $defaultOpts, $class;
}

# Sets the 'base' message to show as part of the update. E.g. "Compiling..."
sub setStatus
{
    my ($self, $newStatus) = @_;
    $self->{status} = $newStatus;
}

# Sets the amount of progress made vs. the total progress possible.
sub setProgress
{
    my ($self, $newProgress) = @_;

    my $oldProgress = $self->{cur_progress};
    $self->{cur_progress} = $newProgress;

    $self->update() if ($oldProgress != $newProgress);
}

# Sets the total amount of progress deemed possible.
sub setProgressTotal
{
    my ($self, $newProgressTotal) = @_;
    $self->{progress_total} = $newProgressTotal;
}

# Sends out the I/O needed to ensure the latest status is displayed.
# E.g. for TTY it clears the line and redisplays the current stats.
sub update
{
    my $self = shift;
    my $total = $self->{progress_total};
    my $msg;
    my $spinner = '-\\|/';

    if ($total > 0) {
        $msg = sprintf ("%s %0.1f%%",
            $self->{status},
            $self->{cur_progress} * 100 / $total,
        );
    }
    else {
        $msg = $self->{status} .
            substr($spinner, $self->{cur_progress} % length($spinner), 1);
    }

    _clearLineAndUpdate($msg);
}

# For TTY outputs, this clears the line (if we actually had dirtied it) so
# the rest of the program can resume output from where it'd been left off.
sub releaseTTY
{
    my $self = shift;
    my $msg = shift // '';

    _clearLineAndUpdate($msg);
}

sub _clearLineAndUpdate
{
    my $msg = shift;

    # Give escape sequence to return to column 1 and clear the entire line
    # Then print message and return to column 1 again in case somewhere else
    # uses the tty.
    print "\e[1G\e[K$msg\e[1G";
    STDOUT->flush;
}

1;
