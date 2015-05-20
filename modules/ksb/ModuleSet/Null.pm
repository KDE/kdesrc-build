package ksb::ModuleSet::Null;

# Class: ModuleSet::Null
#
# Used automatically by <Module> to represent the abscence of a <ModuleSet> without
# requiring definedness checks.

use strict;
use warnings;
use 5.014;

our $VERSION = '0.10';
our @ISA = qw(ksb::ModuleSet);

use ksb::Util;

sub new
{
    my $class = shift;
    return bless {}, $class;
}

sub name
{
    return '';
}

sub convertToModules
{
    croak_internal("kdesrc-build should not have made it to this call. :-(");
}

1;
