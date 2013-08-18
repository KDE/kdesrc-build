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

# Resolves the requested branch-group for this Updater's module.
# Returns the required branch name, or undef if none is set.
sub _resolveBranchGroup
{
    my ($self, $branchGroup) = @_;
    my $module = $self->module();

    # If we're using a logical group we need to query the global build context
    # to resolve it.
    my $ctx = $module->buildContext();
    my $resolver = $ctx->moduleBranchGroupResolver();
    my $modulePath = $module->fullProjectPath();
    return $resolver->findModuleBranch($modulePath, $branchGroup);
}

1;
