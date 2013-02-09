package ksb::Updater::KDEProjectMetadata;

# Updater used only to specifically update the "kde-build-metadata" module
# used for storing dependency information, among other things.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use ksb::Util;
use ksb::Debug;
use ksb::Updater::KDEProject;

our @ISA = qw(ksb::Updater::KDEProject);

sub name
{
    return 'metadata';
}

# Returns a list of the full kde-project paths for each module to ignore.
sub ignoredModules
{
    my $self = assert_isa(shift, 'ksb::Updater::KDEProjectMetadata');
    my $path = $self->module()->fullpath('source') . "/build-script-ignore";

    # Now that we in theory have up-to-date source code, read in the
    # ignore file and propagate that information to our context object.

    my $fh = pretend_open($path) or
        croak_internal("Unable to read ignore data: $!");

    my $ctx = $self->module()->buildContext();
    my @ignoreModules = map  { chomp $_; $_ } # 3 Remove newlines
                        grep { !/^\s*$/ }     # 2 Filter empty lines
                        map  { s/#.*$//; $_ } # 1 Remove comments
                        (<$fh>);

    return @ignoreModules;
}

1;
