# Test detection of dependency cycles in a dependency graph

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

#
# trivial cycle a -> a
#
my $graph1 = {
    'a' => {
        deps => {
            'a' => {}
        }
    },
    'b' => {
        deps => {}
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph1, 'a', 'a'), 1, "should detect 'trivial' cycles of an item to itself");

my $graph2 = {
    'a' => {
        deps => {
            'b' => {}
        }
    },
    'b' => {
        deps => {
            'a' => {}
        }
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph2, 'a', 'a'), 1, "should detect cycle: a -> b -> a");
is(ksb::DependencyResolver::_detectDependencyCycle($graph2, 'b', 'b'), 1, "should detect cycle: b -> a -> b");

#
# no cycles, should therefore not 'detect' any false positives
#
my $graph3 = {
    'a' => {
        deps => {
            'b' => {}
        }
    },
    'b' => {
        deps => {}
    }
};

is(ksb::DependencyResolver::_detectDependencyCycle($graph3, 'a', 'a'), 0, "should not report false positives for 'a'");
is(ksb::DependencyResolver::_detectDependencyCycle($graph3, 'b', 'b'), 0, "should not report false positives for 'b'");

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
