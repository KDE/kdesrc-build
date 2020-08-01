use 5.014;
use strict;
use warnings;

# Checks that we don't inadvertently eat non-option
# arguments in cmdline processing, which happened with
# some cmdline options that were inadvertently handled
# both directly in readCommandLineOptionsAndSelectors
# and indirectly via being in
# ksb::BuildContext::defaultGlobalFlags)
# See bug 402509 -- https://bugs.kde.org/show_bug.cgi?id=402509

use Test::More;

use ksb::Application;
use ksb::Module;

# This bug had affected --stop-on-failure and --disable-snapshots
my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc --stop-on-failure setmod3);

{
    my $app = ksb::Application::newFromCmdline(@args)->setHeadless;
    my @moduleList = $app->modules();

    is (scalar @moduleList, 1, 'Right number of modules (just one)');
    is ($moduleList[0]->name(), 'setmod3', 'mod list[0] == setmod3');
}

$args[-2] = '--disable-snapshots';

{
    my $app = ksb::Application::newFromCmdline(@args)->setHeadless;
    my @moduleList = $app->modules();

    is (scalar @moduleList, 1, 'Right number of modules (just one)');
    is ($moduleList[0]->name(), 'setmod3', 'mod list[0] == setmod3');
}

done_testing();
