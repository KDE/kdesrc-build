package ksb::Updater::KDEProject;

# An update class for KDE Project modules (i.e. those that use "repository
# kde-projects" in the configuration file).

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use ksb::Updater::Git;
our @ISA = qw(ksb::Updater::Git);

use ksb::Debug;

sub name
{
    return 'proj';
}

# Overrides ksb::Updater::Git's version to return the right branch based off
# a logical branch-group, if one is set.
sub getBranch
{
    my $self = shift;
    my $module = $self->module();
    my $branchGroup = $module->getOption('branch-group');

    return $self->SUPER::getBranch() if !$branchGroup;

    # If we're using a logical group we need to query the global build context
    # to resolve it.
    my $ctx = $module->buildContext();
    my $resolver = $ctx->moduleBranchGroupResolver();
    my $modulePath = $module->fullProjectPath();
    my $branch = $resolver->findModuleBranch($modulePath, $branchGroup);

    if (!$branch) {
        whisper ("No specific branch set for $modulePath and $branchGroup, using b[master]");
        $branch = 'master';
    }

    return $branch;
}

1;
