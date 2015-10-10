package ksb::StatusView 0.20;

# Helper used to handle a generic 'progress update' status for the module
# build, update, install, etc. processes.
#
# Currently supports TTY output only but it's not impossible to visualize
# extending this to a GUI or even web server as options.

use strict;
use warnings;
use 5.014;

use ksb::Debug 0.20 qw(colorize);

use IO::Handle;

sub new
{
    my $class = shift;
    my $defaultOpts = {
        cur_progress   => -1,
        progress_total => -1,
        status         => '',

        # Records number of modules built stats
        mod_total      => -1,
        mod_failed     => 0,
        mod_success    => 0,
    };

    # Must bless a hash ref since subclasses expect it.
    return bless $defaultOpts, $class;
}

# Sets the 'base' message to show as part of the update. E.g. "Compiling..."
sub setStatus
{
    my ($self, $newStatus) = @_;
    $self->{status} = colorize($newStatus);
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

# Gets (or sets, if arg provided) number of modules to be built.
sub numberModulesTotal
{
    my ($self, $newTotal) = @_;
    $self->{mod_total} = $newTotal if $newTotal;
    return $self->{mod_total};
}

# Gets (or sets, if arg provided) number of modules built successfully.
sub numberModulesSucceeded
{
    my ($self, $newTotal) = @_;
    $self->{mod_success} = $newTotal if $newTotal;
    return $self->{mod_success};
}

# Gets (or sets, if arg provided) number of modules not built successfully.
sub numberModulesFailed
{
    my ($self, $newTotal) = @_;
    $self->{mod_failed} = $newTotal if $newTotal;
    return $self->{mod_failed};
}

# Sends out the I/O needed to ensure the latest status is displayed.
# E.g. for TTY it clears the line and redisplays the current stats.
sub update
{
    my $self = shift;
    my $progress_total = $self->{progress_total};
    my $msg;

    my ($mod_total, $mod_success, $mod_failed) =
        @{$self}{qw(mod_total mod_success mod_failed)};

    my $fmt_spec = ($mod_total >= 100) ? "%03d" : "%02d";
    my $status_line = $self->{status};

    if ($mod_total > 1) {
        # Build up message in reverse order
        $msg = "$mod_total modules";
        $msg = colorize("r[b[$mod_failed] failed, ") . $msg if $mod_failed;
        $msg = colorize("g[b[$mod_success] built, ") . $msg if $mod_success;

        $status_line = $self->{status} . " ($msg)";
    }

    if ($progress_total > 0) {
        $msg = sprintf ("%0.1f%%",
            $self->{cur_progress} * 100 / $progress_total,
        ) . $status_line;
    }
    elsif ($self->{cur_progress} < 0) {
        $msg = $status_line;
    }
    else {
        my $spinner = '-\\|/';
        $msg =
            substr($spinner, $self->{cur_progress} % length($spinner), 1) .
            $status_line;
    }

    _clearLineAndUpdate($msg);
}

# For TTY outputs, this clears the line (if we actually had dirtied it) so
# the rest of the program can resume output from where it'd been left off.
sub releaseTTY
{
    my $self = shift;
    my $msg = shift // '';

    _clearLineAndUpdate(colorize($msg));
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
