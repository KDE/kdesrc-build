# SPDX-FileCopyrightText: 2019 Johan Ouwerkerk <jm.ouwerkerk@gmail.com>
#
# SPDX-License-Identifier: GPL-2.0-or-later

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

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
