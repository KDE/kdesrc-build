# Test running the full vote for dependencies

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::DependencyResolver;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

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

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();

