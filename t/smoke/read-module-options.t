use 5.014;
use strict;
use warnings;

# Test basic option reading from rc-files

use Test::More;

package ksb::test {
    use Carp qw(confess cluck);
    use Test::More;

    my %inspectors = (
        log_command => \&_inspect_log_command,
    );

    our @CMD;
    our %OPTS;

    sub inspect {
        my $mod = shift;
        my $sub = $inspectors{$mod} or return;
        goto $sub;
    };

    sub _inspect_log_command
    {
        my ($module, $filename, $argRef, $optionsRef) = @_;
        confess "No arg to module" unless $argRef;
        my @command = @{$argRef};
        if (grep { $_ eq 'cmake' } @command) {
            @CMD = @command;
            %OPTS = %{$optionsRef};
        }
    };

    1;
};

use ksb::Application;
use ksb::Util qw(trimmed);

my $app = ksb::Application->new(qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc));
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

ok(@ksb::test::CMD, 'log_command cmake was called');
is(scalar (@ksb::test::CMD), 8);

is($ksb::test::CMD[0], 'cmake', 'CMake command should start with cmake');
is($ksb::test::CMD[1], '/tmp/setmod2', 'CMake command should specify source directory as first argument');
is($ksb::test::CMD[2], '-G', 'CMake generator should be specified explicitly');
is($ksb::test::CMD[3], 'Unix Makefiles', 'Expect the default CMake generator to be used');
is($ksb::test::CMD[4], '-DCMAKE_BUILD_TYPE=a b', 'CMake options can be quoted');
is($ksb::test::CMD[5], 'bar=c', 'CMake option quoting does not eat all options');
is($ksb::test::CMD[6], 'baz', 'Plain CMake options are preserved correctly');
is($ksb::test::CMD[7], "-DCMAKE_INSTALL_PREFIX=$ENV{HOME}/kde", 'Prefix is passed to cmake');

# See https://phabricator.kde.org/D18165
is($moduleList[0]->getOption('cxxflags'), '', 'empty cxxflags renders with no whitespace in module');

done_testing();
