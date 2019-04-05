use 5.014;
use strict;
use warnings;

# Test sorting modules into build order

use Test::More;

use ksb::DependencyResolver;

my $graph1 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 1,
        module => 'a'
    },
    'b' => {
        votes => {},
        build => 1,
        module => 'b'
    },
    'c' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => 'c'
    },
    'd' => {
        votes => {},
        build => 1,
        module => 'd'
    }
};


my @expected1 = ('a', 'c', 'b', 'd');
my @actual1 = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph1);

is_deeply(\@actual1, \@expected1, "should sort modules into the proper build order");

# use some random key strokes for names:
# unlikely to yield keys in equivalent order as $graph1: key order *should not matter*
my $graph2 = {
    'avdnrvrl' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => 'c'
    },
    'lexical1' => {
        votes => {},
        build => 1,
        module => 'b'
    },
    'nllfmvrb' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 1,
        module => 'a'
    },
    'lexical2' => {
        votes => {},
        build => 1,
        module => 'd'
    }
};

my @expected2 = ('a', 'c', 'b', 'd');
my @actual2 = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph2);

is_deeply(\@actual2, \@expected2, "key order should not matter for build order");

my $graph3 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 0,
        module => 'a'
    },
    'b' => {
        votes => {},
        build => 1,
        module => undef
    },
    'c' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => 'c'
    },
    'd' => {
        votes => {},
        build => 1,
        module => 'd'
    }
};

my @expected3 = ('c', 'd');
my @actual3 = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph3);

is_deeply(\@actual3, \@expected3, "modules that are not to be built should be omitted");

done_testing();
