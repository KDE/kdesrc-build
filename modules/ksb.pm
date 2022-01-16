package ksb;

# Enables default boilerplate Perl standards used by kdesrc-build, including minimum Perl version,
# strictness, warnings, etc.
#
# See also: Modern::Perl
#
# Use by including 'use ksb;' at the beginning of each kdesrc-build source file.

use v5.28;

# These are imported to make *this* pragma strict and enable warnings. We will
# then re-import these into our caller's namespace in our own sub import.
use strict;
use warnings;

# These are made available but not imported. They are only here so we can
# re-import them into the caller's namespace.
use experimental();
use feature ();

my $REQUIRED_PERL_FEATURES = ':5.28';

my @EXPERIMENTAL_FEATURES = qw(smartmatch);

sub import
{
    warnings->import;
    strict->import;
    feature->import ($REQUIRED_PERL_FEATURES);
    experimental->import (@EXPERIMENTAL_FEATURES);
}

1;
