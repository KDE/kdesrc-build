package ksb::Updater::KDEProject;

# An update class for KDE Project modules (i.e. those that use "repository
# kde-projects" in the configuration file).

use strict;
use warnings;
use v5.10;

use ksb::Updater::Git;
our @ISA = qw(ksb::Updater::Git);

sub name
{
    return 'proj';
}

1;
