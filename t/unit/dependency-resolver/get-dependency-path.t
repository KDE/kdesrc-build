use v5.22;
use strict;
use warnings;

#
# Verify that _getDependencyPathOf() works properly
#
use Test::More;

use ksb::DependencyResolver;

# Redefine ksb::Module to stub fullProjectPath() results
package ksb::Module {
    no warnings 'redefine';

    sub new
    {
        my ($class, $projectPath, $kde) = @_;

        my $self = {
            projectPath => $projectPath,
            kde => $kde
        };

        bless $self, $class;
        return $self;
    }

    sub isKDEProject
    {
        my $self = shift;
        return $self->{kde};
    }

    sub fullProjectPath
    {
        my $self = shift;
        return $self->{projectPath};
    }
};

my $module1 = ksb::Module->new('test/path', 1);

is(ksb::DependencyResolver::_getDependencyPathOf($module1, 'foo', 'bar'), 'test/path', "should return full project path if a KDE module object is passed");

my $module2 = undef;

is(ksb::DependencyResolver::_getDependencyPathOf($module2, 'foo', 'bar'), 'bar', "should return the provided default if no module is passed");

my $module3 = ksb::Module->new('test/path', 0);
is(ksb::DependencyResolver::_getDependencyPathOf($module3, 'foo', 'bar'), 'third-party/test/path', "should return 'third-party/' prefixed project path if a non-KDE module object is passed");

done_testing();

