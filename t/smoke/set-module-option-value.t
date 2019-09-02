use 5.014;
use strict;
use warnings;

# Test use of --set-module-option-value

use Test::More;

use ksb::Application;

my @args = (qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc
    --set-module-option-value), 'module2,tag,fake-tag10',
   '--set-module-option-value', 'setmod2,tag,tag-setmod10');
my $app = ksb::Application->new;
my @selectors = $app->establishContext(@args);
my $workload = $app->modulesFromSelectors(@selectors);
$app->setModulesToProcess($workload);
my @moduleList = $app->modules();

is(scalar @moduleList, 4, 'Right number of modules');

my $scm = $moduleList[0]->scm();
my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag10', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

($branch, $type) = $moduleList[2]->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod10', 'Right tag name (options block from cmdline)');
is($type, 'tag', 'cmdline options block came back as tag');

ok(!$moduleList[2]->isKDEProject(), 'setmod2 is *not* a "KDE" project');
is($moduleList[2]->fullProjectPath(), 'setmod2', 'fullProjectPath on non-KDE modules returns name');

done_testing();
