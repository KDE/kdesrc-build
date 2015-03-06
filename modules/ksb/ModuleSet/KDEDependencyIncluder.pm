package ksb::ModuleSet::KDEDependencyIncluder;

# Class: ModuleSet::KDEDependencyIncluder
#
# A special kde-projects ModuleSet, which is intended to be used for modules
# included automatically based on dependency data within kde-build-metadata.
#
# Since these dependencies may include 'virtual' dependencies this module set
# is much more lenient on whether the module request needs to exist or not.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';
our @ISA = qw(ksb::ModuleSet::KDEProjects);

use ksb::Util;

sub convertToModules
{
    my $self = shift;

    my @returnModules = eval { $self->SUPER::convertToModules(@_) };

    return if $@; # Return nothing if an error encountered (but don't croak)
    return @returnModules;
}

1;
