use v5.22;
use strict;
use warnings;

# Test running the full vote for dependencies

use Test::More;

use ksb::DependencyResolver;

my $graph1 = {
    'a' => {
        votes => {},
        allDeps => {
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'b' => {
        votes => {},
        allDeps => {
            items => {
                'c' => 1
            }
        }
    },
    'c' => {
        votes => {},
        allDeps => {
            items => {}
        }
    },
    #
    # an item might depend through multiple (transitive) paths on the same
    # dependency at the same time
    #
    'd' => {
        votes => {},
        allDeps => {
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'e' => {
        votes => {},
        allDeps => {
            items => {}
        }
    }
};

my $expected1 = {
    'a' => {
        votes => {},
        allDeps => {
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'b' => {
        votes => {
            'a' => 1,
            'd' => 1
        },
        allDeps => {
            items => {
                'c' => 1
            }
        }
    },
    'c' => {
        votes => {
            'a' => 1,
            'b' => 1,
            'd' => 1
        },
        allDeps => {
            items => {}
        }
    },
    'd' => {
        votes => {},
        allDeps => {
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'e' => {
        votes => {},
        allDeps => {
            items => {}
        }
    }
};

ksb::DependencyResolver::_runDependencyVote($graph1);

is_deeply($graph1, $expected1, "should yield expected votes");

done_testing();
