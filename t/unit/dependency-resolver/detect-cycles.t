use v5.22;
use strict;
use warnings;

# Test detection of dependency cycles in a dependency graph

use Test::More;

use ksb::DependencyResolver;

#
# trivial cycle a -> a
#
my $graph1 = {
    'a' => {
        deps => {
            'a' => {}
        }
    },
    'b' => {
        deps => {}
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph1, 'a', 'a'), 1, "should detect 'trivial' cycles of an item to itself");

my $graph2 = {
    'a' => {
        deps => {
            'b' => {}
        }
    },
    'b' => {
        deps => {
            'a' => {}
        }
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph2, 'a', 'a'), 1, "should detect cycle: a -> b -> a");
is(ksb::DependencyResolver::_detectDependencyCycle($graph2, 'b', 'b'), 1, "should detect cycle: b -> a -> b");

#
# no cycles, should therefore not 'detect' any false positives
#
my $graph3 = {
    'a' => {
        deps => {
            'b' => {}
        }
    },
    'b' => {
        deps => {}
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph3, 'a', 'a'), 0, "should not report false positives for 'a'");
is(ksb::DependencyResolver::_detectDependencyCycle($graph3, 'b', 'b'), 0, "should not report false positives for 'b'");

done_testing();
