# SPDX-FileCopyrightText: 2012 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::IPC::Null 0.10;

# Dummy IPC module in case SysVIPC doesn't work or async mode is not needed.

use ksb;

use parent qw(ksb::IPC);

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

