# SPDX-FileCopyrightText: 2012 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::Updater 0.20;

use ksb;

=head1 DESCRIPTION

Base class for classes that handle updating the source code for a given
L<ksb::Module>.  It should not be used directly.

=cut

use ksb::BuildException;

sub new
{
    my ($class, $module) = @_;

    return bless { module => $module }, $class;
}

sub name
{
    croak_internal('This package should not be used directly.');
}

sub module
{
    my $self = shift;
    return $self->{module};
}

1;
