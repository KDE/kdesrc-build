package ksb::IPC::Pipe;

# IPC class that uses pipes for communication.  Basically requires forking two
# children in order to communicate with.  Assumes that the two children are the
# update process and a monitor process which keeps the update going and informs
# us (the build process) of the status when we're ready to hear about it.

use strict;
use warnings;
use v5.10;

use IO::Handle;
use ksb::IPC;
our @ISA = qw(ksb::IPC);

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new;

    # Define file handles.
    $self->{$_} = new IO::Handle foreach qw/fromMon toMon fromSvn toBuild/;

    if (not pipe($self->{'fromSvn'}, $self->{'toMon'})or
        not pipe($self->{'fromMon'}, $self->{'toBuild'}))
    {
        return undef;
    }

    return bless $self, $class;
}

# Must override to send to correct filehandle.
sub notifyUpdateSuccess
{
    my $self = shift;
    my ($module, $msg) = @_;

    $self->sendIPCMessage(ksb::IPC::MODULE_SUCCESS, "$module,$msg", 'toMon');
}

# Closes the given list of filehandle ids.
sub closeFilehandles
{
    my $self = shift;
    my @fhs = @_;

    for my $fh (@fhs) {
        close $self->{$fh};
        $self->{$fh} = 0;
    }
}

# Call this to let the object know it will be the update process.
sub setUpdater
{
    my $self = shift;
    $self->closeFilehandles(qw/fromSvn fromMon toBuild/);
}

sub setBuilder
{
    my $self = shift;
    $self->closeFilehandles(qw/fromSvn toMon toBuild/);
}

sub setMonitor
{
    my $self = shift;
    $self->closeFilehandles(qw/toMon fromMon/);
}

sub supportsConcurrency
{
    return 1;
}

# First parameter is the ipc Type of the message to send.
# Second parameter is the module name (or other message).
# Third parameter is the file handle id to send on.
sub sendMessage
{
    my $self = shift;
    my ($msg, $fh) = @_;

    return syswrite ($self->{$fh}, $msg);
}

# Override of sendIPCMessage to specify which filehandle to send to.
sub sendIPCMessage
{
    my $self = shift;
    push @_, 'toMon'; # Add filehandle to args.

    return $self->SUPER::sendIPCMessage(@_);
}

# Used by monitor process, so no message encoding or decoding required.
sub sendToBuilder
{
    my ($self, $msg) = @_;
    return $self->sendMessage($msg, 'toBuild');
}

# First parameter is a reference to the output buffer.
# Second parameter is the id of the filehandle to read from.
sub receiveMessage
{
    my $self = shift;
    my $fh = shift;
    my $value;

    undef $!; # Clear error marker
    my $result = sysread ($self->{$fh}, $value, 256);

    return undef if not $result;
    return $value;
}

# Override of receiveIPCMessage to specify which filehandle to receive from.
sub receiveIPCMessage
{
    my $self = shift;
    push @_, 'fromMon'; # Add filehandle to args.

    return $self->SUPER::receiveIPCMessage(@_);
}

# Used by monitor process, so no message encoding or decoding required.
sub receiveFromUpdater
{
    my $self = shift;
    return $self->receiveMessage('fromSvn');
}

1;

