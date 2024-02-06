# Test basic option reading from rc-files

use ksb;
use ksb::Util (); # load early so we can override

use Mojo::Util qw(monkey_patch);
use Mojo::Promise;

use Test::More;
use Carp qw(confess);
use POSIX;
use File::Basename;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

# Override ksb::Util::log_command for final test to see if it is called with
# 'cmake'
my @CMD;

# Very important that this happens in a BEGIN block so that it happens before
# ksb::Application is loaded, so that ksb::Util's log_command method can be
# overridden before it is copied to dependents packages' symbol tables
BEGIN {
    monkey_patch('ksb::Util',
        run_logged_p => sub ($module, $filename, $dir, $argRef) {
            confess "No arg to module" unless $argRef;
            my @command = @{$argRef};
            if (grep { $_ eq 'cmake' } @command) {
                @CMD = @command;
            }
            return Mojo::Promise->resolve(0);
        });
}

# Now we can load ksb::Application, which will load a bunch more modules all
# using log_command and run_logged_p from ksb::Util
use ksb::Application;

my $app = ksb::Application->new(qw(--pretend --rc-file t/integration/fixtures/sample-rc/kdesrc-buildrc));
my @moduleList = @{$app->{modules}};

is(scalar @moduleList, 4, 'Right number of modules');

# module2 is last in rc-file so should sort last
is($moduleList[3]->name(), 'module2', 'Right module name');

my $scm = $moduleList[3]->scm();
isa_ok($scm, 'ksb::Updater::Git');

my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag5', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

# setmod2 is second module in set of 3 at start, should be second overall
is($moduleList[1]->name(), 'setmod2', 'Right module name from module-set');
($branch, $type) = $moduleList[1]->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod2', 'Right tag name (options block)');
is($type, 'tag', 'options block came back as tag');

#
# Test some of the option parsing indirectly by seeing how the value is input
# into build system.
#

# Override auto-detection since no source is downloaded
$moduleList[1]->setOption('override-build-system', 'kde');

# Should do nothing in --pretend
ok($moduleList[1]->setupBuildSystem(), 'setup fake build system');

ok(@CMD, 'run_logged_p cmake was called');
is(scalar (@CMD), 12);

is($CMD[ 0], 'cmake', 'CMake command should start with cmake');
is($CMD[ 1], '-B',    'Passed build dir to cmake');
is($CMD[ 2], '.',     'Passed cur dir as build dir to cmake');
is($CMD[ 3], '-S',    'Pass source dir to cmake');
is($CMD[ 4], '/tmp/setmod2', 'CMake command should specify source directory after -S');
is($CMD[ 5], '-G', 'CMake generator should be specified explicitly');
is($CMD[ 6], 'Unix Makefiles', 'Expect the default CMake generator to be used');
is($CMD[ 7], '-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON', 'Per default we generate compile_commands.json');
is($CMD[ 8], '-DCMAKE_BUILD_TYPE=a b', 'CMake options can be quoted');
is($CMD[ 9], 'bar=c', 'CMake option quoting does not eat all options');
is($CMD[10], 'baz', 'Plain CMake options are preserved correctly');
is($CMD[11], "-DCMAKE_INSTALL_PREFIX=$ENV{HOME}/kde/usr", 'Prefix is passed to cmake');

# See https://phabricator.kde.org/D18165
is($moduleList[0]->getOption('cxxflags'), '', 'empty cxxflags renders with no whitespace in module');

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
