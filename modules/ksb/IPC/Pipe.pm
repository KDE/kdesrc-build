package ksb::IPC::Pipe;

# IPC class that uses pipes in addition to forking for IPC.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.20';

use ksb::IPC;
our @ISA = qw(ksb::IPC);

use ksb::Util qw(croak_internal croak_runtime);

use IO::Handle;
use IO::Pipe;
use Errno qw(EINTR);

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new;

    # Define file handles.
    $self->{fh} = IO::Pipe->new();

    return bless $self, $class;
}

# Call this to let the object know it will be the update process.
sub setSender
{
    my $self = shift;

    $self->{fh}->writer();

    # Disable buffering
    $self->{fh}->autoflush(1);
}

sub setReceiver
{
    my $self = shift;

    $self->{fh}->reader();

    # Disable buffering
    $self->{fh}->autoflush(1);
}

# Reimplementation of ksb::IPC::supportsConcurrency
sub supportsConcurrency
{
    return 1;
}

# Required reimplementation of ksb::IPC::sendMessage
# First parameter is the (encoded) message to send.
sub sendMessage
{
    my ($self, $msg) = @_;

    # Since streaming does not provide message boundaries, we will insert
    # ourselves, by sending a 2-byte unsigned length, then the message.
    my $encodedMsg = pack ("S a*", length($msg), $msg);

    if (length($encodedMsg) != $self->{fh}->syswrite($encodedMsg)) {
        croak_runtime("Unable to write full msg to pipe: $!");
    }

    return 1;
}

sub _readNumberOfBytes
{
    my ($self, $length) = @_;

    my $fh = $self->{fh};
    my $readLength = 0;
    my $result;

    while ($readLength < $length) {
        $! = 0; # Reset errno

        my $curLength = $fh->sysread ($result, ($length - $readLength), $readLength);
        if ($curLength > $length) {
            croak_runtime("sysread read too much: $curLength vs $length")
        }

        # EINTR is OK, but check early so we don't trip 0-length check
        next   if (!defined $curLength && $!{EINTR});
        return if (defined $curLength && $curLength == 0);
        croak_runtime ("Error reading $length bytes from pipe: $!") if !$curLength;

        $readLength += $curLength;
    }

    return $result;
}

# Required reimplementation of ksb::IPC::receiveMessage
sub receiveMessage
{
    my $self = shift;

    # Read unsigned short with msg length, then the message
    my $msgLength = $self->_readNumberOfBytes(2);
    return if !$msgLength;

    $msgLength = unpack ("S", $msgLength); # Decode to Perl type
    return $self->_readNumberOfBytes($msgLength);
}

sub close
{
    my $self = shift;
    $self->{fh}->close();
}

1;

