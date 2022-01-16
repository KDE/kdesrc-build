# Test running the full vote for dependencies

use ksb;
use Test::More;

use ksb::DependencyResolver;

my $graph1 = {
    'a' => {
        deps => {
            'b' => 1
        },
        allDeps => {}
    },
    'b' => {
        deps => {
            'c' => 1
        },
        allDeps => {}
    },
    'c' => {
        deps => {},
        allDeps => {}
    },
    #
    # an item might depend through multiple (transitive) paths on the same
    # dependency at the same time
    #
    'd' => {
        deps => {
            'b' => 1,
            'c' => 1
        },
        allDeps => {}
    },
    'e' => {
        deps => {},
        allDeps => {}
    }
};

my $expected1 = {
    'a' => {
        deps => {
            'b' => 1
        },
        allDeps => {
            done => 1,
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'b' => {
        deps => {
            'c' => 1
        },
        allDeps => {
            done => 1,
            items => {
                'c' => 1
            }
        }
    },
    'c' => {
        deps => {},
        allDeps => {
            done => 1,
            items => {}
        }
    },
    'd' => {
        deps => {
            'b' => 1,
            'c' => 1
        },
        allDeps => {
            done => 1,
            items => {
                'b' => 1,
                'c' => 1
            }
        }
    },
    'e' => {
        deps => {},
        allDeps => {
            done => 1,
            items => {}
        }
    }
};

is_deeply(ksb::DependencyResolver::_copyUpDependencies($graph1), $expected1, "should copy up dependencies correctly");

done_testing();

