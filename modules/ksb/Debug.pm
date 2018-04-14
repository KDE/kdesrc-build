package ksb::Debug 0.30;

# Debugging routines and constants for use with kdesrc-build

use strict;
use warnings;
use 5.014;

use Storable qw(freeze);

use Exporter qw(import); # Steal Exporter's import method
our @EXPORT = qw(debug pretending debugging whisper
                 note info warning error pretend);
our @EXPORT_OK = qw(colorize);

# Debugging level constants.
use constant {
    DEBUG   => 0,
    WHISPER => 1,
    INFO    => 2,
    NOTE    => 3,
    WARNING => 4,
    ERROR   => 5,
};

my $screenLog;   # Filehandle pointing to the "build log".
my $isPretending = 0;
my $debugLevel = INFO;

my $ipc;         # Set only if we should forward log messages over IPC.

# Colors
my ($RED, $GREEN, $YELLOW, $NORMAL, $BOLD, $DIM) = ("") x 6;

# Subroutine definitions

sub colorize
{
    my $str = shift;

    $str =~ s/g\[/$GREEN/g;
    $str =~ s/]/$NORMAL/g;
    $str =~ s/y\[/$YELLOW/g;
    $str =~ s/r\[/$RED/g;
    $str =~ s/b\[/$BOLD/g;
    $str =~ s/d\[/$DIM/g;

    return $str;
}

# Removes color decorators, whether colorful output is enabled or not
sub stripDecorators
{
    my $str = shift;

    $str =~ s/[gyrbd]\[//g;
    $str =~ s/]//g;

    return $str;
}

# Subroutine which returns true if pretend mode is on.  Uses the prototype
# feature so you don't need the parentheses to use it.
sub pretending()
{
    return $isPretending;
}

sub setPretending
{
    $isPretending = shift;
}

sub setColorfulOutput
{
    # No colors unless output to a tty.
    return unless -t STDOUT;

    my $useColor = shift;

    if ($useColor) {
        $RED    = "\e[31m";
        $GREEN  = "\e[32m";
        $YELLOW = "\e[33m";
        $NORMAL = "\e[0m";
        $BOLD   = "\e[1m";
        $DIM    = "\e[34m"; # Really blue since dim doesn't work on konsole

        # But konsole does support xterm-256color...
        $DIM    = "\e[38;5;8m" if $ENV{TERM} =~ /-256color$/;
    }
    else {
        ($RED, $GREEN, $YELLOW, $NORMAL, $BOLD, $DIM) = ("") x 6;
    }
}

# Subroutine which returns true if debug mode is on.  Uses the prototype
# feature so you don't need the parentheses to use it.
sub debugging(;$)
{
    my $level = shift // DEBUG;
    return $debugLevel <= $level;
}

sub setDebugLevel
{
    $debugLevel = shift;
}

sub setLogFile
{
    my $fileName = shift;

    return if pretending();
    open ($screenLog, '>', $fileName) or error ("Unable to open log file $fileName!");
}

# Sets an IPC object to use to proxy logged messages over, to avoid having
# multiple procs fighting over the same TTY. Needless to say, you should only
# bother with this if the IPC method is actually concurrent.
sub setOutputHandle
{
    $ipc = shift;
    die "$ipc isn't an IO handle!" if (!$ipc->can('syswrite'));
}

# The next few subroutines are used to print output at different importance
# levels to allow for e.g. quiet switches, or verbose switches.  The levels are,
# from least to most important:
# debug, whisper, info (default), note (quiet), warning (very-quiet), and error.
#
# You can also use the pretend output subroutine, which is emitted if pretend
# mode is enabled.
#
# ksb::Debug::colorize is automatically run on the input for all of those
# functions.  Also, the terminal color is automatically reset to normal as
# well so you don't need to manually add the ] to reset.

# Subroutine used to actually display the data, calls ksb::Debug::colorize on each entry first.
sub print_clr(@)
{
    my @items = @_;

    if (defined $screenLog || $ipc) {
        my $msg = join('', map { +stripDecorators($_) } (@items));

        if (defined $screenLog) {
            say $screenLog $msg;
        }

        # If we have an IPC object that means the real kdesrc-build is a different proc
        # and we should forward log entries back to it, unless used for line-spacing only
        if ($ipc && $msg) {
            my $msgs = freeze([$msg]);
            $ipc->syswrite($msgs) or say "Couldn't write to debugging output handle: $!";
        }
        return if $ipc; # don't concurrently spam to TTY
    }

    # Leading + prevents Perl from assuming the plain word "colorize" is actually
    # a filehandle or future reserved word.
    print +colorize($_) foreach (@items);
    print +colorize("]\n");

}

sub debug(@)
{
    print_clr(@_) if debugging;
}

sub whisper(@)
{
    print_clr(@_) if $debugLevel <= WHISPER;
}

sub info(@)
{
    print_clr(@_) if $debugLevel <= INFO;
}

sub note(@)
{
    print_clr(@_) if $debugLevel <= NOTE;
}

sub warning(@)
{
    print_clr(@_) if $debugLevel <= WARNING;
}

sub error(@)
{
    print STDERR (colorize $_) foreach (@_);
    print STDERR (colorize "]\n");
}

sub pretend(@)
{
    if (pretending() && $debugLevel <= WHISPER) {
        my @lines = @_;
        s/(\w)/d[$1/ foreach @lines; # Add dim prefix
                                     # Clear suffix is actually implicit
        print_clr(@lines);
    }
}

1;
