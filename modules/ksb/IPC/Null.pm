package ksb::IPC::Null;

# Dummy IPC module in case SysVIPC doesn't work or async mode is not needed.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use ksb::IPC;
our @ISA = qw(ksb::IPC);

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new;

    $self->{'msgList'} = []; # List of messages.
    return bless $self, $class; # OOP in Perl is so completely retarded
}

sub sendMessage
{
    my $self = shift;
    my $msg = shift;

    push @{$self->{'msgList'}}, $msg;
    return 1;
}

sub receiveMessage
{
    my $self = shift;

    return undef unless scalar @{$self->{'msgList'}} > 0;

    return shift @{$self->{'msgList'}};
}

1;

