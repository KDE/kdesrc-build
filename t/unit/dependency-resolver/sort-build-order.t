use 5.014;
use strict;
use warnings;

# Test sorting modules into build order

use Test::More;

use ksb::DependencyResolver;

# Redefine ksb::Module to stub isKDEProject() results
package ksb::Module {
    no warnings 'redefine';

    sub new
    {
        my ($class, $kde, $name) = @_;

        my $self = {
            kde => $kde,
            name => $name
        };

        bless $self, $class;
        return $self;
    }

    sub isKDEProject
    {
        my $self = shift;
        return $self->{kde};
    }

    sub name
    {
        my $self = shift;
        return $self->{name};
    }
};

my $graph1 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 1,
        module => new ksb::Module(1, 'a')
    },
    'b' => {
        votes => {},
        build => 1,
        module => new ksb::Module(1, 'b')
    },
    'c' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => new ksb::Module(1, 'c')
    },
    'd' => {
        votes => {},
        build => 1,
        module => new ksb::Module(1, 'd')
    },
    'e' => {
        votes => {},
        build => 1,
        module => new ksb::Module(0, 'e')
    },
    'f' => {
        votes => {},
        build => 1,
        module => new ksb::Module(0, 'f')
    }
};


my @expected1 = ('e', 'f', 'a', 'c', 'b', 'd');
my @actual1 = map { $_->name() } (ksb::DependencyResolver::sortModulesIntoBuildOrder($graph1));

is_deeply(\@actual1, \@expected1, "should sort modules into the proper build order");

# use some random key strokes for names:
# unlikely to yield keys in equivalent order as $graph1: key order *should not matter*
my $graph2 = {
    'avdnrvrl' => {
        votes => {
            'd' => 1
        },
        build => 1,
        module => new ksb::Module(1, 'c')
    },
    'lexical1' => {
        votes => {},
        build => 1,
        module => new ksb::Module(1, 'b')
    },
    'nllfmvrb' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 1,
        module => new ksb::Module(1, 'a')
    },
    'lexical2' => {
        votes => {},
        build => 1,
        module => new ksb::Module(1, 'd')
    },
    'non-KDE-f' => {
        votes => {},
        build => 1,
        module => new ksb::Module(0, 'f')
    },
    'non-KDE-e' => {
        votes => {},
        build => 1,
        module => new ksb::Module(0, 'e')
    }
};

my @expected2 = ('e', 'f', 'a', 'c', 'b', 'd');
my @actual2 = map { $_->name() } (ksb::DependencyResolver::sortModulesIntoBuildOrder($graph2));

is_deeply(\@actual2, \@expected2, "key order should not matter for build order");

my $graph3 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        build => 0,
        module => new ksb::Module(1, 'a')
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
        module => new ksb::Module(1, 'c')
    },
    'd' => {
        votes => {},
        build => 1,
        module => new ksb::Module(1, 'd')
    }
};

my @expected3 = ('c', 'd');
my @actual3 = map { $_->name() } (ksb::DependencyResolver::sortModulesIntoBuildOrder($graph3));

is_deeply(\@actual3, \@expected3, "modules that are not to be built should be omitted");

done_testing();
