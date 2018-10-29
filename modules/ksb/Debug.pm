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

my $pipeToParent; # Set in child subprocesses, can write to this to send data back

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

# Sets a pipe to use to proxy logged messages, progress info, etc. back to our
# parent
sub setOutputHandle
{
    $pipeToParent = shift;
    die "$pipeToParent isn't an IO handle!"
        unless $pipeToParent->can('syswrite');
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
sub _print_clr
{
    my ($msgDebugLevel, @items) = @_;

    return unless $debugLevel <= $msgDebugLevel;

    if (defined $screenLog || $pipeToParent) {
        my $msg = join('', map { +stripDecorators($_) } (@items));

        say $screenLog $msg
            if defined $screenLog;

        # If we have an pipe, that means the parent kdesrc-build owns TTY.
        if ($pipeToParent && $msg) {
            # $msg can be blank if used for newlines
            _sendMessageToParent({ message => $msg}) if $msg;
            return;
        }
    }

    # Leading + prevents Perl from assuming the plain word "colorize" is actually
    # a filehandle or future reserved word.
    print +colorize($_) foreach (@items);
    print +colorize("]\n");

}

sub _sendMessageToParent
{
    croak_internal("Missing pipe to parent")
        unless $pipeToParent;

    my $obj_ref = shift;
    $pipeToParent->syswrite(freeze($obj_ref))
        or croak_internal("Failed to write msg to parent $!, aborting");
}

sub reportProgressToParent
{
    my ($module, $x, $y) = @_;
    _sendMessageToParent({ progress => [ 0+$x, 0+$y ], module => "$module" });
}

sub debug(@)
{
    _print_clr(DEBUG, @_);
}

sub whisper(@)
{
    _print_clr(WHISPER, @_);
}

sub info(@)
{
    _print_clr(INFO, @_);
}

sub note(@)
{
    _print_clr(NOTE, @_);
}

sub warning(@)
{
    _print_clr(WARNING, @_);
}

sub error(@)
{
    _print_clr(ERROR, @_);
}

sub pretend(@)
{
    if (pretending() && $debugLevel <= WHISPER) {
        my @lines = @_;
        s/(\w)/d[$1/ foreach @lines; # Add dim prefix
                                     # Clear suffix is actually implicit
        _print_clr($debugLevel, @lines);
    }
}

1;
