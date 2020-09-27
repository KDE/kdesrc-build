package ksb::Updater::KDEProject 0.20;

# An update class for KDE Project modules (i.e. those that use "repository
# kde-projects" in the configuration file).

use strict;
use warnings;
use v5.22;

use parent qw(ksb::Updater::Git);

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

# Reimplementation
sub _moduleIsNeeded
{
    my $self = shift;
    my $module = $self->module();

    # selected-by looks at cmdline options, found-by looks at how we read
    # module info from rc-file in first place to select it from cmdline.
    # Basically if user asks for it on cmdline directly or in rc-file directly
    # then we need to try to grab it...
    if (($module->getOption('#selected-by', 'module') // '') ne 'name' &&
        ($module->getOption('#found-by',    'module') // '') eq 'wildcard')
    {
        return 0;
    }

    return 1;
}

# Reimplementation
sub _isPlausibleExistingRemote
{
    my ($self, $name, $url, $configuredUrl)= @_;
    return $url eq $configuredUrl || $url =~ /^kde:/;
}

# Reimplementation
sub isPushUrlManaged
{
    return 1;
}

1;
