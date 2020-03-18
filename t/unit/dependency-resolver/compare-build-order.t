use 5.014;
use strict;
use warnings;

# Test comparison operation for sorting modules into build order

use Test::More;

use ksb::DependencyResolver;

my $graph1 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        module => {
            name => 'a',
        },
    },
    'b' => {
        votes => {},
        module => {
            name => 'b',
        },
    },
    'c' => {
        votes => {
            'd' => 1
        },
        module => {
            name => 'c',
        },
    },
    'd' => {
        votes => {},
        module => {
            name => 'd',
        },
    },
    'e' => {  # Here to test sorting by rc-file order
        votes => {
            'b' => 1,
            'd' => 1,
        },
        module => {
            name => 'e',
            '#create-id' => 1,
        },
    },
};

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'a'),  0, "'a' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'b'), -1, "'a' should be sorted before 'b' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'c'), -1, "'a' should be sorted before 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'd'), -1, "'a' should be sorted before 'd' by dependency ordering");
# e doesn't depend on a, has same number of votes, but should still lose to a despite lexicographically being after 'a'
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'e'), -1, "'a' should be sorted before 'e' by rc-file ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'a'),  1, "'b' should be sorted after 'a' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'b'),  0, "'b' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'c'),  1, "'b' should be sorted after 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'd'), -1, "'b' should be sorted before 'd' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'e'),  1, "'b' should be sorted after 'e' by dependency ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'a'),  1, "'c' should be sorted after 'a' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'b'), -1, "'c' should be sorted before 'b' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'c'),  0, "'c' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'd'), -1, "'c' should be sorted before 'd' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'e'),  1, "'c' should be sorted after 'e' by vote ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'a'),  1, "'d' should be sorted after 'a' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'b'),  1, "'d' should be sorted after 'b' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'c'),  1, "'d' should be sorted after 'c' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'd'),  0, "'d' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'e'),  1, "'d' should be sorted after 'e' by dependency ordering");

done_testing();
