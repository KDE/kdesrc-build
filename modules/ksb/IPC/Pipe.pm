package ksb::IPC::Pipe 0.20;

# IPC class that uses pipes in addition to forking for IPC.

use ksb;

use parent qw(ksb::IPC);

use ksb::BuildException;

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

    # Disable buffering and any possibility of IO 'interpretation' of the bytes
    $self->{fh}->autoflush(1);
    binmode($self->{fh})
}

sub setReceiver
{
    my $self = shift;

    $self->{fh}->reader();

    # Disable buffering and any possibility of IO 'interpretation' of the bytes
    $self->{fh}->autoflush(1);
    binmode($self->{fh})
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
    my $result = $self->{fh}->syswrite($encodedMsg);

    if (!$result || length($encodedMsg) != $result) {
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

        # EINTR is OK, but check early so we don't trip 0-length check
        next   if (!defined $curLength && $!{EINTR});
        return if (defined $curLength && $curLength == 0);
        croak_internal("Error reading $length bytes from pipe: $!")
            if !$curLength;
        croak_internal("sysread read too much: $curLength vs $length")
            if ($curLength > $length);

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
    if (!$msgLength) {
        croak_internal ("Failed to read $msgLength bytes as needed by earlier message!");
    }

    return $self->_readNumberOfBytes($msgLength);
}

sub close
{
    my $self = shift;
    $self->{fh}->close();
}

1;

