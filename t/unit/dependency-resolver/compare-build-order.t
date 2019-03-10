use 5.014;
use strict;
use warnings;

# Test comparison operation for sorting modules into build order

use Test::More;

use ksb::DependencyResolver;

# Redefine ksb::Module to stub isKDEProject() results
package ksb::Module {
    no warnings 'redefine';

    sub new
    {
        my ($class, $kde) = @_;

        my $self = {
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
};

my $graph1 = {
    'a' => {
        votes => {
            'b' => 1,
            'd' => 1
        },
        module => new ksb::Module(1)
    },
    'b' => {
        votes => {},
        module => new ksb::Module(1)
    },
    'c' => {
        votes => {
            'd' => 1
        },
        module => new ksb::Module(1)
    },
    'd' => {
        votes => {},
        module => new ksb::Module(1)
    },
    'e' => {
        votes => {},,
        module => new ksb::Module(0)
    },
    'f' => => {
        votes => {},,
        module => new ksb::Module(0)
    }
};

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'a'),  0, "'a' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'b'), -1, "'a' should be sorted before 'b' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'c'), -1, "'a' should be sorted before 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'd'), -1, "'a' should be sorted before 'd' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'e'),  1, "'a' should be sorted after 'e' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'a', 'f'),  1, "'a' should be sorted after 'f' by prioritising non-KDE modules over KDE ones");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'a'),  1, "'b' should be sorted after 'a' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'b'),  0, "'b' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'c'),  1, "'b' should be sorted after 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'd'), -1, "'b' should be sorted before 'd' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'e'),  1, "'b' should be sorted after 'e' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'b', 'f'),  1, "'b' should be sorted after 'f' by prioritising non-KDE modules over KDE ones");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'a'),  1, "'c' should be sorted after 'c' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'b'), -1, "'c' should be sorted before 'b' by vote ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'c'),  0, "'c' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'd'), -1, "'c' should be sorted before 'd' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'e'),  1, "'c' should be sorted after 'e' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'c', 'f'),  1, "'c' should be sorted after 'f' by prioritising non-KDE modules over KDE ones");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'a'),  1, "'d' should be sorted after 'a' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'b'),  1, "'d' should be sorted after 'b' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'c'),  1, "'d' should be sorted after 'c' by dependency ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'd'),  0, "'d' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'e'),  1, "'d' should be sorted after 'e' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'd', 'f'),  1, "'d' should be sorted after 'f' by prioritising non-KDE modules over KDE ones");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'a'), -1, "'e' should be sorted before 'a' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'b'), -1, "'e' should be sorted before 'b' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'c'), -1, "'e' should be sorted before 'c' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'd'), -1, "'e' should be sorted before 'd' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'e'),  0, "'e' should be sorted at the same position as itself");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'e', 'f'), -1, "'e' should be sorted before 'f' by lexicographic ordering");

is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'a'), -1, "'f' should be sorted before 'a' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'b'), -1, "'f' should be sorted before 'b' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'c'), -1, "'f' should be sorted before 'c' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'd'), -1, "'f' should be sorted before 'd' by prioritising non-KDE modules over KDE ones");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'e'),  1, "'f' should be sorted after 'e' by lexicographic ordering");
is(ksb::DependencyResolver::_compareBuildOrder($graph1, 'f', 'f'),  0, "'f' should be sorted at the same position as itself");

done_testing();
