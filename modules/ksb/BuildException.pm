package ksb::BuildException;

# A class to wrap 'exception' messages for the script, allowing them to be
# dispatch based on type and automatically stringified.

use v5.10; # Needed for state keyword
use strict;
use warnings;
use overload
    '""' => \&to_string;

our $VERSION = '0.10';

sub new
{
    my ($class, $type, $msg) = @_;

    return bless({
        'exception_type' => $type,
        'message'        => $msg,
    }, $class);
}

sub to_string
{
    my $exception = shift;
    return $exception->{exception_type} . " Error: " . $exception->{message};
}

1;
