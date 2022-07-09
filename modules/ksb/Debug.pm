package ksb::Debug 0.20;

# Debugging routines and constants for use with kdesrc-build

use ksb;

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

# Subroutine which returns true if pretend mode is on.  Uses the prototype
# feature so you don't need the parentheses to use it.
sub pretending :prototype()
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

sub isLogLevel
{
    my $level = shift // DEBUG;
    return $debugLevel <= $level;
}

# Subroutine which returns true if debug mode is on.
sub debugging :prototype(;$)
{
    return isLogLevel(DEBUG);
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
sub setIPC
{
    $ipc = shift;
    die "$ipc isn't an IPC obj!" if (!ref ($ipc) || !$ipc->isa('ksb::IPC'));
}

# The next few subroutines are used to print output at different importance
# levels to allow for e.g. quiet switches, or verbose switches.  The levels are,
# from least to most important:
# debug, whisper, info (default), note (quiet), warning (very-quiet), and error.
#
# You can also use the pretend output subroutine, which is emitted if, and only
# if pretend mode is enabled.
#
# ksb::Debug::colorize is automatically run on the input for all of those
# functions.  Also, the terminal color is automatically reset to normal as
# well so you don't need to manually add the ] to reset.

# Subroutine used to actually display the data, calls ksb::Debug::colorize on each entry first.
sub print_clr :prototype(@)
{
    # If we have an IPC object that means there's multiple procs trying to
    # share the same TTY. Just forward messages to the one proc that should be
    # managing the TTY.
    if ($ipc) {
        my $msg = join('', @_);
        $ipc->sendLogMessage($msg);
        return;
    }

    # Leading + prevents Perl from assuming the plain word "colorize" is actually
    # a filehandle or future reserved word.
    print +colorize($_) foreach (@_);
    print +colorize("]\n");

    if (defined $screenLog) {
        my @savedColors = ($RED, $GREEN, $YELLOW, $NORMAL, $BOLD);
        # Remove color but still extract codes
        ($RED, $GREEN, $YELLOW, $NORMAL, $BOLD) = ("") x 5;

        print ($screenLog colorize($_)) foreach (@_);
        print ($screenLog "\n");

        ($RED, $GREEN, $YELLOW, $NORMAL, $BOLD) = @savedColors;
    }
}

sub debug :prototype(@)
{
    print_clr(@_) if isLogLevel(DEBUG);
}

sub whisper :prototype(@)
{
    print_clr(@_) if isLogLevel(WHISPER);
}

sub info :prototype(@)
{
    print_clr(@_) if isLogLevel(INFO);
}

sub note :prototype(@)
{
    print_clr(@_) if isLogLevel(NOTE);
}

sub warning :prototype(@)
{
    print_clr(@_) if isLogLevel(WARNING);
}

sub error :prototype(@)
{
    print STDERR (colorize $_) foreach (@_);
    print STDERR (colorize "]\n");
}

sub pretend :prototype(@)
{
    if (pretending() && $debugLevel <= WHISPER) {
        my @lines = @_;
        s/(\w)/d[$1/ foreach @lines; # Add dim prefix
                                     # Clear suffix is actually implicit
        print_clr(@lines);
    }
}

1;
