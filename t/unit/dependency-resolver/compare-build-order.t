use v5.22;
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
            '#create-id' => 2,
        },
    },
    'f' => {  # Identical to 'e' except it's simulated earlier in rc-file
        votes => {
            'b' => 1,
            'd' => 1,
        },
        module => {
            name => 'f',
            '#create-id' => 1,
        },
    },
};

# Test that tests are symmetric e.g. a > b => b < a. This permits us to only manually
# test one pair of these tests now that the test matrix is growing.
for my $l ('a'..'f') {
    for my $r ('a'..'f') {
        my $res = ksb::DependencyResolver::_compareBuildOrder($graph1, $l, $r);

        if ($l eq $r) {
            is($res, 0, "'$l' should be sorted at the same position as itself");
        }
        else {
            is(abs($res), 1, "Different module items ('$l' and '$r') compare to 1 or -1 (but not 0)");
            is(ksb::DependencyResolver::_compareBuildOrder($graph1, $r, $l), -$res,
                "Swapping order of operands should negate the result ('$r' vs '$l')");
        }
    }
}

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'b'), -1, "'a' should be sorted before 'b' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'c'), -1, "'a' should be sorted before 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'd'), -1, "'a' should be sorted before 'd' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'e'), -1, "'a' should be sorted before 'e' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'f'), -1, "'a' should be sorted before 'f' by lexicographic ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'c'),  1, "'b' should be sorted after 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'd'), -1, "'b' should be sorted before 'd' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'e'),  1, "'b' should be sorted after 'e' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'f'),  1, "'b' should be sorted after 'f' by dependency ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'd'), -1, "'c' should be sorted before 'd' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'e'),  1, "'c' should be sorted after 'e' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'f'),  1, "'c' should be sorted after 'f' by vote ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'e'),  1, "'d' should be sorted after 'e' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'f'),  1, "'d' should be sorted after 'f' by dependency ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'f'),  1, "'e' should be sorted after 'f' by rc-file ordering");

done_testing();
