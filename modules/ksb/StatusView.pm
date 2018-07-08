package ksb::StatusView 0.30;

# Helper used to handle a generic 'progress update' status for the module
# build, update, install, etc. processes.
#
# Currently supports TTY output only but it's not impossible to visualize
# extending this to a GUI or even web server as options.

use strict;
use warnings;
use 5.014;

use ksb::Debug 0.20 qw(colorize);
use ksb::Util;
use List::Util qw(max reduce);

use IO::Handle;

sub new
{
    my $class = shift;

    my $tty_width = int(`tput cols` // $ENV{COLUMNS} // 80);

    my $defaultOpts = {
        tty_width       => $tty_width,
        max_name_width  => 1,   # Updated from the build plan
        cur_update      => '',  # moduleName under update
        cur_working     => '',  # moduleName under any other phase
        cur_progress    => '',  # Percentage (0% - 100%)

        module_in_phase => { }, # $phase -> $moduleName
        done_in_phase   => { }, # $phase -> int
        todo_in_phase   => { }, # $phase -> int
        failed_at_phase => { }, # $moduleName -> $phase
    };

    # Must bless a hash ref since subclasses expect it.
    return bless $defaultOpts, $class;
}

# Accepts a single event, as a hashref decoded from its source JSON format (as
# described in ksb::StatusMonitor), and updates the user interface
# appropriately.
sub notifyEvent
{
    my ($self, $ev) = @_;
    state $handlers = {
        phase_started   => \&onPhaseStarted,
        phase_progress  => \&onPhaseProgress,
        phase_completed => \&onPhaseCompleted,
        build_plan      => \&onBuildPlan,
        build_done      => \&onBuildDone,
        log_entries     => \&onLogEntries,
    };
    state $err = sub { croak_internal("Invalid event! $_[1]"); };

    my $handler = $handlers->{$ev->{event}} // $err;

    # This is a method call though we don't use normal Perl method call syntax
    $handler->($self, $ev);
}

# Event handlers

# A module has started on a given phase. Multiple phases can be in-flight at
# once!
sub onPhaseStarted
{
    my ($self, $ev) = @_;
    my ($moduleName, $phase) =
        @{$ev->{phase_started}}{qw/module phase/};

    $self->{module_in_phase}->{$phase} = $moduleName;
    my $phaseKey = $phase eq 'update' ? 'cur_update' : 'cur_working';
    $self->{$phaseKey} = $moduleName;

    $self->update();
}

# Progress has been made within a phase of a module build. Only supported for
# the build phase, currently.
sub onPhaseProgress
{
    my ($self, $ev) = @_;
    my ($moduleName, $phase, $progress) =
        @{$ev->{phase_progress}}{qw/module phase progress/};
    $progress = sprintf ("%3.1f", 100.0 * $progress);
    $self->{cur_progress} = $progress;

    $self->update();
}

# A phase of a module build is finished
sub onPhaseCompleted
{
    my ($self, $ev) = @_;
    my ($moduleName, $phase, $result) =
        @{$ev->{phase_completed}}{qw/module phase result/};

    if ($result eq 'error') {
        $self->{failed_at_phase}->{$moduleName} = $phase;
    }

    $self->{done_in_phase}->{$phase}++;
    my $phase_done = (
        ($self->{done_in_phase}->{$phase} // 0) ==
        ($self->{todo_in_phase}->{$phase} // 999));

    my $phaseKey = $phase eq 'update' ? 'cur_update' : 'cur_working';
    $self->{$phaseKey} = $phase_done ? '---' : '';

    if ($phase ne 'update') {
        _clearLine();
        say "Done with $moduleName";
    }

    # See if we have any phases left to do, displaying an update block w/out
    # work to do just looks messy.
    my $phases_left = reduce {
        $a +
        ($self->{todo_in_phase}->{$b} - $self->{done_in_phase}->{$b})
    } 0, keys %{$self->{todo_in_phase}};

    $self->update() if $phases_left;
}

# The one-time build plan has been given, can be used for deciding best way to
# show progress
sub onBuildPlan
{
    my ($self, $ev) = @_;
    my (@modules) =
        @{$ev->{build_plan}};

    croak_internal ("Empty build plan!") unless @modules;

    my %num_todo;
    my $max_name_width = 0;

    for my $m (@modules) {
        $max_name_width = max($max_name_width, length $m->{name});
        $num_todo{$_}++ foreach (@{$m->{phases}});
    }

    say "*** Received build plan for ", scalar @modules, " modules";
}

# The whole build/install process has completed.
sub onBuildDone
{
    my ($self, $ev) = @_;
    my ($statsRef) =
        %{$ev->{build_done}};

    say "\n*** Build done!";

    while (my ($phase, $v) = each %{$self->{todo_in_phase}}) {
        if ($self->{done_in_phase}->{$phase} != $v) {
            say " !!!! Not every phase was accounted for in $phase!";
        }
    }
}

# The build/install process has forwarded new notices that should be shown.
sub onLogEntries
{
    my ($self, $ev) = @_;
    my ($module, $phase, $entriesRef) =
        @{$ev->{log_entries}}{qw/module phase entries/};

    _clearLine(); # Current line may have a transient update msg still

    for my $entry (@$entriesRef) {
        say "$module($phase): $entry";
    }
}

# TTY helpers

sub update
{
    my $self = shift;
    my $up   = $self->{cur_update}   || '???';
    my $work = $self->{cur_working}  || '???';
    my $prog = $self->{cur_progress} || '??';

    $up = 'N/A' unless ($self->{todo_in_phase}->{update} // 0) > 0;

    my $msg = "Updating: [$up]. Working on [$work], $prog% done";
    _clearLineAndUpdate("$msg");
}

sub _clearLine
{
    print "\e[1G\e[K";
}

sub _clearLineAndUpdate
{
    my $msg = shift;

    # Give escape sequence to return to column 1 and clear the entire line,
    # then prints message.
    print "\e[1G\e[K$msg";
    STDOUT->flush;
}

1;
