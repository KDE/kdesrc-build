# Test comparison operation for sorting modules into debug order

use ksb;
use Test::More;

use ksb::DebugOrderHints;

# Redefine ksb::Module to stub getPersistentOption() results
package ksb::Module {
    no warnings 'redefine';

    sub new
    {
        my ($class, $name, $count) = @_;

        my $self = {
            count => $count,
            name => $name
        };

        bless $self, $class;
        return $self;
    }

    sub getPersistentOption
    {
        my $self = shift;
        my $option = shift;
        Test::More::is($option, 'failure-count', "only the 'failure-count' should be queried");
        return $self->{count};
    }

    sub name
    {
        my $self = shift;
        return $self->{name};
    }
};

my $a1 = new ksb::Module('A:i-d2-v0-c0', 0);
my $b1 = new ksb::Module('B:i-d1-v1-c0', 0);
my $c1 = new ksb::Module('C:i-d0-v0-c0', 0);
my $d1 = new ksb::Module('D:i-d0-v0-c1', 1);
my $e1 = new ksb::Module('E:i-d0-v1-c0', 0);

# test: ordering of modules that fail in the same phase based on dependency info
my $graph1 = {
    $c1->name() => {
        votes => {},
        deps => {},
        module => $c1
    },
    $d1->name() => {
        votes => {},
        deps => {},
        module => $d1
    },
    $e1->name() => {
        votes => {
            $a1->name() => 1
        },
        deps => {},
        module => $e1
    },
    $b1->name() => {
        votes => {
            $a1->name() => 1
        },
        deps => { 'foo' => 1 },
        module => $b1
    },
    $a1->name() => {
        votes => {},
        deps => {
            $e1->name() => 1,
            $b1->name() => 1
        },
        module => $a1
    }
};

my $extraDebugInfo1 = {
    phases => {
        $a1->name() => 'install',
        $b1->name() => 'install',
        $c1->name() => 'install',
        $d1->name() => 'install',
        $e1->name() => 'install'
    }
};

is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $c1, $c1),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $c1, $d1), -1, "No dependency relation ship, root causes, same popularity: the 'newest' failure (lower count) should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $c1, $e1),  1, "No dependency relation ship, root causes: the higher popularity should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $c1, $b1), -1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $c1, $a1), -1, "No dependency relation ship: the root cause should be sorted first");

is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $d1, $c1),  1, "No dependency relation ship, root causes, same popularity: the 'newest' failure (lower count) should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $d1, $d1),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $d1, $e1),  1, "No dependency relation ship, root causes: the higher popularity should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $d1, $b1), -1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $d1, $a1), -1, "No dependency relation ship: the root cause should be sorted first");

is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $e1, $c1), -1, "No dependency relation ship, root causes: the higher popularity should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $e1, $d1), -1, "No dependency relation ship, root causes: the higher popularity should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $e1, $e1),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $e1, $b1), -1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $e1, $a1), -1, "Dependencies should be sorted before dependent modules");

is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $b1, $c1),  1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $b1, $d1),  1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $b1, $e1),  1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $b1, $b1),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $b1, $a1), -1, "Dependencies should be sorted before dependent modules");

is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $a1, $c1),  1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $a1, $d1),  1, "No dependency relation ship: the root cause should be sorted first");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $a1, $e1),  1, "Dependencies should be sorted before dependent modules");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $a1, $b1),  1, "Dependencies should be sorted before dependent modules");
is(ksb::DebugOrderHints::_compareDebugOrder($graph1, $extraDebugInfo1, $a1, $a1),  0, "Comparing the same modules should always yield the same relative position");

# test: ordering of modules that fail in different phases
my $p_b1 = new ksb::Module('build1', 0);
my $p_b2 = new ksb::Module('build2', 0);
my $p_i = new ksb::Module('install', 0);
my $p_t = new ksb::Module('test', 0);
my $p_u = new ksb::Module('update', 0);
my $p_x = new ksb::Module('unknown', 0);

my $graph2 = {
    $p_b1->name() => {
        votes => {},
        deps => {},
        module => $p_b1
    },
    $p_b2->name() => {
        votes => {},
        deps => {},
        module => $p_b2
    },
    $p_i->name() => {
        votes => {},
        deps => {},
        module => $p_i
    },
    $p_t->name() => {
        votes => {},
        deps => {},
        module => $p_t
    },
    $p_u->name() => {
        votes => {},
        deps => {},
        module => $p_u
    },
    $p_x->name() => {
        votes => {},
        deps => {},
        module => $p_x
    }
};

my $extraDebugInfo2 = {
    phases => {
        $p_b1->name() => 'build',
        $p_b2->name() => 'build',
        $p_i->name() => 'install',
        $p_t->name() => 'test',
        $p_u->name() => 'update',
        $p_x->name() => 'unknown'
    }
};

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_b1),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_b2), -1, "Same phase: sort by name for reproducibility");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_i ),  1, "Phase ordering: 'build' should be sorted after 'install'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_t ),  1, "Phase ordering: 'build' should be sorted after 'test'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_u ), -1, "Phase ordering: 'build' should be sorted before 'update'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b1, $p_x ), -1, "Phase ordering: 'build' should be sorted before unsupported phases");

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_b1),  1, "Same phase: sort by name for reproducibility");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_b2),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_i ),  1, "Phase ordering: 'build' should be sorted after 'install'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_t ),  1, "Phase ordering: 'build' should be sorted after 'test'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_u ), -1, "Phase ordering: 'build' should be sorted before 'update'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_b2, $p_x ), -1, "Phase ordering: 'build' should be sorted before unsupported phases");

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_b1), -1, "Phase ordering: 'install' should be sorted before 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_b2), -1, "Phase ordering: 'install' should be sorted before 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_i ),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_t ), -1, "Phase ordering: 'install' should be sorted before 'test'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_u ), -1, "Phase ordering: 'install' should be sorted before 'update'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_i,  $p_x ), -1, "Phase ordering: 'install' should be sorted before unsupported phases");

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_b1), -1, "Phase ordering: 'test' should be sorted before 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_b2), -1, "Phase ordering: 'test' should be sorted before 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_i ),  1, "Phase ordering: 'test' should be sorted after 'install'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_t ),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_u ), -1, "Phase ordering: 'test' should be sorted before 'update'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_t,  $p_x ), -1, "Phase ordering: 'test' should be sorted before unsupported phases");

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_b1),  1, "Phase ordering: 'update' should be sorted after 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_b2),  1, "Phase ordering: 'update' should be sorted after 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_i ),  1, "Phase ordering: 'update' should be sorted after 'install'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_t ),  1, "Phase ordering: 'update' should be sorted after 'test'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_u ),  0, "Comparing the same modules should always yield the same relative position");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_u,  $p_x ), -1, "Phase ordering: 'update' should be sorted before unsupported phases");

is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_b1),  1, "Phase ordering: unknown phases should be sorted after 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_b2),  1, "Phase ordering: unknown phases should be sorted after 'build'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_i ),  1, "Phase ordering: unknown phases should be sorted after 'install'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_t ),  1, "Phase ordering: unknown phases should be sorted after 'test'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_u ),  1, "Phase ordering: unknown phases should be sorted after 'update'");
is(ksb::DebugOrderHints::_compareDebugOrder($graph2, $extraDebugInfo2, $p_x,  $p_x ),  0, "Comparing the same modules should always yield the same relative position");

done_testing();
