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

sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::KDEProjectMetadata');
    my $count = $self->SUPER::updateInternal();

    # Now that we in theory have up-to-date source code, read in the
    # ignore file and propagate that information to our context object.

    my $path = $self->module()->fullpath('source') . "/build-script-ignore";

    my $fh = pretend_open($path) or
        croak_internal("Unable to read ignore data: $!");

    my $ctx = $self->module()->buildContext();
    my @ignoreModules = map { chomp $_; $_ } (<$fh>);

    $ctx->setIgnoreList(@ignoreModules);

    return $count;
}

1;
