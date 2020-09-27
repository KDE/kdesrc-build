package ksb::Updater;

# Base class for classes that handle updating the source code for a given ksb::Module.
# It should not be used directly.

use warnings;
use v5.22;

our $VERSION = '0.10';

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
