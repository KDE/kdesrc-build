use 5.014;
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
        my ($class, $projectPath) = @_;

        my $self = {
            projectPath => $projectPath,
        };

        bless $self, $class;
        return $self;
    }

    sub fullProjectPath
    {
        my $self = shift;
        return $self->{projectPath};
    }
};

my $module1 = ksb::Module->new('test/path');

is(ksb::DependencyResolver::_getDependencyPathOf($module1, 'foo', 'bar'), 'test/path', "should return full project path if a module object is passed");

my $module2 = undef;

is(ksb::DependencyResolver::_getDependencyPathOf($module2, 'foo', 'bar'), 'bar', "should return the provided default if no module is passed");

done_testing();

