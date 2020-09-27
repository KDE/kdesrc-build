use v5.22;
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
        module => {
            name => 'a',
            '#create-id' => 1,
        },
    },
    'b' => {
        votes => {},
        build => 1,
        module => {
            name => 'b',
            '#create-id' => 1,
        },
    },
    'c' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => {
            name => 'c',
            '#create-id' => 1,
        },
    },
    'd' => {
        votes => {},
        build => 1,
        module => {
            name => 'd',
            '#create-id' => 1,
        },
    },
    'e' => {
        votes => {},
        build => 1,
        module => {
            name => 'e',
            '#create-id' => 2, # Should come after everything else
        },
    },
};


my @expected1 = map { $graph1->{$_}->{module} } ('a', 'c', 'b', 'd', 'e');
my @actual1   = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph1);

is_deeply(\@actual1, \@expected1, "should sort modules into the proper build order");

# use some random key strokes for names:
# unlikely to yield keys in equivalent order as $graph1: key order *should not matter*
my $graph2 = {
    'avdnrvrl' => $graph1->{c},
    'lexical1' => $graph1->{b},
    'lexicla3' => $graph1->{e},
    'nllfmvrb' => $graph1->{a},
    'lexical2' => $graph1->{d},
};

# corresponds to same order as the test above
my @expected2 = map { $graph2->{$_}->{module} } qw(nllfmvrb avdnrvrl lexical1 lexical2 lexicla3);
my @actual2   = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph2);

is_deeply(\@actual2, \@expected2, "key order should not matter for build order");

my $graph3 = {
    'a' => $graph1->{a},
    'b' => $graph1->{b},
    'c' => $graph1->{c},
    'd' => $graph1->{d},
    'e' => $graph1->{e},
};
$graph3->{a}->{build} = 0;
$graph3->{b}->{module} = undef; # Empty module blocks should be treated as build == 0

my @expected3 = map { $graph3->{$_}->{module} } ('c', 'd', 'e');
my @actual3   = ksb::DependencyResolver::sortModulesIntoBuildOrder($graph3);

is_deeply(\@actual3, \@expected3, "modules that are not to be built should be omitted");

done_testing();
