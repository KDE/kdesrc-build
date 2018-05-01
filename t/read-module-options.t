use 5.014;
use strict;
use warnings;

# Test basic option reading from rc-files

use Test::More;

use ksb::Application;

my $app = ksb::Application->new(qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc));
my @moduleList = @{$app->{modules}};

is(scalar @moduleList, 4, 'Right number of modules');
is($moduleList[3]->name(), 'module2', 'Right module name');

my $scm = $moduleList[3]->scm();
isa_ok($scm, 'ksb::Updater::Git');

my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag5', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

is($moduleList[1]->name(), 'setmod2', 'Right module name from module-set');
($branch, $type) = $moduleList[1]->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod2', 'Right tag name (options block)');
is($type, 'tag', 'options block came back as tag');

done_testing();
