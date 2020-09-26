package ksb::StatusView 0.30;

use utf8; # Source code is utf8-encoded

# Helper used to handle a generic 'progress update' status for the module
# build, update, install, etc. processes.
#
# Currently supports TTY output only but it's not impossible to visualize
# extending this to a GUI or even web server as options.

use strict;
use warnings;
use 5.014;

# our output to STDOUT should match locale (esp UTF-8 locale, which induces
# warnings for UTF-8 output unless we specifically opt-in)
use open OUT => ':locale';

use ksb::Debug 0.20 qw(colorize);
use ksb::Util;
use ksb::BuildException;
use List::Util qw(min max reduce first);

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
        log_entries     => { }, # $moduleName -> $phase -> [ $entry ... ]
        last_mod_entry  => '',  # $moduleName/$phase, see onLogEntries
        last_msg_type   => '',  # If 'progress' we can clear line
        warnings        => { }, # $moduleName -> $sum_of_warnings
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
        new_postbuild_message => sub { return }, # no-op
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

# Writes out a line to TTY noting information about the module that just finished
# (elapsed time, compile warnings, success/failure, etc.)
# Pass in the monitor event for the 'phase_completed' event
sub _showModuleFinishResults
{
    my ($self, $ev) = @_;
    my ($moduleName, $phase, $result) =
        @{$ev->{phase_completed}}{qw/module phase result/};
    my $modulePhasePlan = $self->{planned_phases}->{$moduleName};

    my %shortPhases = (
        update      => 'Upd',
        buildsystem => 'Cnf',
        build       => 'Bld',
        test        => 'Tst',
        install     => 'Ins',
        uninstall   => 'Uns',
    );

    my %resultColors = (
        success => 'g',
        error   => 'r',
        skipped => 'y',
        pending => 'y',
    );

    my %resultState = (
        success => 'Success:',
        error   => 'Failed :',
        skipped => 'Skipped:',
        pending => 'Waiting:',
    );

    # Locate this module's specific build plan from the ordered array
    my $modulePlan =
        first { $_->{name} eq $moduleName }
            @{$self->{build_plan}};

    # Turn each planned phase into a colorized representation of its success or failure
    my $done_phases =
        join(' / ',
            map { my $clr = $resultColors{$modulePhasePlan->{$_}} // 'y'; "$clr" . "[$shortPhases{$_}]" }
            @{$modulePlan->{phases}});

    my $overallColor = $resultColors{$result} // '';

    # Space out module names so that the whole list is table-aligned
    my $fixedLengthName = sprintf("%-*s", $self->{max_name_width}, $moduleName);

    my $printedTime = prettify_seconds($ev->{phase_completed}->{elapsed} // 0);

    my $notes = '';
    my $warnings = $self->{warnings}->{$moduleName};
    $notes .= "$warnings compiler warnings" if $warnings;

    my $stateToPrint = $resultState{$result} // '???????:';
    $notes = "| $notes" if $notes; # Only show separator if there are notes to print

    my $msg = " ${overallColor}[b[*] ${overallColor}[$stateToPrint b[$fixedLengthName] $printedTime $done_phases $notes";
    $self->_clearLineAndUpdate(colorize("$msg\n"));
}

# A phase of a module build is finished
sub onPhaseCompleted
{
    my ($self, $ev) = @_;
    my ($moduleName, $phase, $result) =
        @{$ev->{phase_completed}}{qw/module phase result/};
    my $modulePhasePlan = $self->{planned_phases}->{$moduleName};

    $self->_checkForBuildPlan();

    $modulePhasePlan->{$phase} = $result;

    $self->{warnings}->{$moduleName} //= 0;
    $self->{warnings}->{$moduleName} += $ev->{phase_completed}->{warnings} // 0;

    if ($result eq 'error') {
        $self->{failed_at_phase}->{$moduleName} = $phase;

        # The phases should all eventually become failed but we should
        # still flag them here in case they don't
        while (my ($phase, $result) = each %{$modulePhasePlan}) {
            $modulePhasePlan->{$phase} = 'skipped' if $result eq 'pending';
        }
    }

    # Are we completely done building the module?
    if (!first { $_ eq 'pending' } values %{$modulePhasePlan}) {
        $self->_showModuleFinishResults($ev);
    }

    # Update global progress bar
    $self->{done_in_phase}->{$phase}++;
    my $phase_done = (
        ($self->{done_in_phase}->{$phase} // 0) ==
        ($self->{todo_in_phase}->{$phase} // 999));

    my $phaseKey = $phase eq 'update' ? 'cur_update' : 'cur_working';
    $self->{$phaseKey} = $phase_done ? '---' : '';

    $self->update();
}

# The one-time build plan has been given, can be used for deciding best way to
# show progress
#
# Looks like:
# {
#   "build_plan": [
#     {
#       "name": "juk",
#       "phases": [
#         "build",
#         "install"
#       ]
#     }
#   ],
#   "event": "build_plan"
# }
sub onBuildPlan
{
    my ($self, $ev) = @_;
    my (@modules)   = @{$ev->{build_plan}};

    croak_internal ("Empty build plan!")
        unless @modules;
    croak_internal ("Already received a plan!")
        if exists $self->{planned_phases};

    my %num_todo = (
        # These are the 'core' phases we expect to be here even with
        # --no-src, --no-build, etc.
        update => 0,
        build  => 0,
    );
    my $max_name_width = 0;

    $self->{planned_phases} = { };

    for my $m (@modules) {
        my @phases = @{$m->{phases}};
        $max_name_width = max($max_name_width, length $m->{name});
        $num_todo{$_}++ foreach @phases;
        $self->{planned_phases}->{$m->{name}} = { map { ($_, 'pending') } @phases };
    }

    $self->{done_in_phase}->{$_} = 0 foreach keys %num_todo;
    $self->{todo_in_phase}  = \%num_todo;
    $self->{max_name_width} = $max_name_width;
    $self->{build_plan}     = $ev->{build_plan};
}

# The whole build/install process has completed.
sub onBuildDone
{
    my ($self, $ev) = @_;
    my ($statsRef) =
        %{$ev->{build_done}};

    # --stop-on-failure can cause modules to skip
    my $numTotalModules = max(
        map { $self->{todo_in_phase}->{$_} } (
            keys %{$self->{todo_in_phase}}));
    my $numFailedModules = keys %{$self->{failed_at_phase}};
    my $numBuiltModules = max(
        map { $self->{done_in_phase}->{$_} } (
            keys %{$self->{done_in_phase}}));
    my $numSuccesses = $numBuiltModules - $numFailedModules;
    my $numSkipped = $numTotalModules - $numBuiltModules;

    my $unicode = ($ENV{LC_ALL} // 'C') =~ /UTF-?8$/;
    my $happy = $unicode ? '✓' : ':-)';
    my $frown = $unicode ? '✗' : ':-(';

    my $built = $numFailedModules == 0
        ? " g[b[$happy] - Built all"
        : " r[b[$frown] - Worked on";

    my $msg = "$built b[$numTotalModules] modules";
    if ($numSkipped > 0 || $numFailedModules > 0) {
        $msg .= " (b[g[$numSuccesses] built OK, b[r[$numFailedModules] failed"
            if $numFailedModules > 0;
        $msg .= ", b[$numSkipped] skipped"
            if $numSkipped > 0;
        $msg .= ")";
    }
    $self->_clearLineAndUpdate (colorize("$msg\n"));
}

# The build/install process has forwarded new notices that should be shown.
sub onLogEntries
{
    my ($self, $ev) = @_;
    my ($module, $phase, $entriesRef) =
        @{$ev->{log_entries}}{qw/module phase entries/};

    # Current line may have a transient update msg still, otherwise we're already on
    # suitable line to print
    _clearLine() if $self->{last_msg_type} eq 'progress';

    if ("$module/$phase" ne $self->{last_mod_entry} && @$entriesRef) {
        say colorize(" b[y[*] b[$module] $phase:");
        $self->{last_mod_entry} = "$module/$phase";
    }

    for my $entry (@$entriesRef) {
        say $entry;

        $self->{log_entries}->{$module} //= { build => [ ], update => [ ] };
        $self->{log_entries}->{$module}->{$phase} //= [ ];
        push @{$self->{log_entries}->{$module}->{$phase}}, $entry;
    }

    $self->{last_msg_type} = 'log';
    $self->update();
}

# TTY helpers

sub _checkForBuildPlan
{
    my $self = shift;

    croak_internal ("Did not receive build plan!")
        unless keys %{$self->{todo_in_phase}};
}

# Generates a string like "update [20/74] build [02/74]" for the requested
# phases.
sub _progressStringForPhases
{
    my ($self, @phases) = @_;
    my $result = '';
    my $base   = '';

    foreach my $phase (@phases) {
        my $cur = $self->{done_in_phase}->{$phase} // 0;
        my $max = $self->{todo_in_phase}->{$phase} // 0;

        my $strWidth = length("$max");
        my $progress = sprintf("%0*s/$max", $strWidth, $cur);

        $result .= "$base$phase [$progress]";
        $base = ' ';
    }

    return $result;
}

# Generates a string like "update: kcoreaddons build: kconfig" for the
# requested phases. You must pass in a hashref mapping each phase name to the
# current module name.
sub _currentModuleStringForPhases
{
    my ($self, $currentModulesRef, @phases) = @_;
    my $result = '';
    my $base   = '';
    my $longestNameWidth = $self->{max_name_width};

    for my $phase (@phases) {
        my $curModule = $currentModulesRef->{$phase} // '???';

        $curModule .= (' ' x ($longestNameWidth - length ($curModule)));

        $result .= "$base$phase: $curModule";
        $base = ' ';
    }

    return $result;
}

# Returns integer length of the worst-case output line (i.e. the one with a
# long module name for each of the given phases).
sub _getMinimumOutputWidth
{
    my ($self, @phases) = @_;
    my $longestName = 'x' x $self->{max_name_width};
    my %mockModules = map { ($_, $longestName) } @phases;

    # fake that the worst-case module is set and find resultant length
    my $str
        = $self->_progressStringForPhases(@phases)
        . " "
        . $self->_currentModuleStringForPhases(\%mockModules, @phases);

    return length($str);
}

sub update
{
    my @phases = qw(update build);

    my $self = shift;
    my $term_width = $self->{tty_width};
    $self->{min_output} //= $self->_getMinimumOutputWidth(@phases);
    my $min_width = $self->{min_output};

    my $progress = $self->_progressStringForPhases(@phases);
    my $current_modules = $self->_currentModuleStringForPhases(
        { update => $self->{cur_update}, build => $self->{cur_working} },
        @phases
        );

    my $msg;

    if ($min_width >= ($term_width - 12)) {
        # No room for fancy progress, just display what we can
        $msg = "$progress $current_modules";
        substr($msg, $term_width - 1) = ''; # Strip off excess to avoid breaking TTY
    } else {
        my $max_prog_width = ($term_width - $min_width) - 5;
        my $num_all_done  = min(@{$self->{done_in_phase}}{@phases}) // 0;
        my $num_some_done = max(@{$self->{done_in_phase}}{@phases}, 0) // 0;
        my $max_todo      = max(@{$self->{todo_in_phase}}{@phases}, 1) // 1;

        my $width = $max_prog_width * $num_all_done / $max_todo;
        # Leave at least one empty space if we're not fully done
        $width-- if ($width == $max_prog_width && $num_all_done < $max_todo);

        my $bar = ('=' x $width);

        # Show a smaller character entry for updates that are done before the
        # corresponding build/install.
        if ($num_some_done > $num_all_done) {
            $width = $max_prog_width * $num_some_done / $max_todo;
            $bar .= ('.' x ($width - length ($bar)));
        }

        $msg = sprintf("%s [%*s] %s", $progress, -$max_prog_width, $bar, $current_modules);
    }

    $self->_clearLineAndUpdate($msg);
    $self->{last_msg_type} = 'progress';
}

sub _clearLine
{
    print "\e[1G\e[K";
}

sub _clearLineAndUpdate
{
    my ($self, $msg) = @_;

    # If last message was a transient progress meter, gives the escape sequence
    # to return to column 1 and clear the entire line before printing message
    $msg = "\e[1G\e[K$msg" if $self->{last_msg_type} eq 'progress';

    print $msg;
    STDOUT->flush;

    $self->{last_msg_type} = 'log'; # update() will change it back if needed
}

1;
