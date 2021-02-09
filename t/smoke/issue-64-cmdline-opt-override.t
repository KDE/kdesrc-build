use 5.014;
use strict;
use warnings;

# Global options in the rc-file can be overridden on the command line just by
# using their option name in a cmdline argument (as long as the argument isn't
# already allocated, that is).
#
# This ensures that global options overridden in this fashion are applied
# before the rc-file is read.
#
# See issue #64

use Test::More;

use ksb::Application;
use ksb::Module;

# The issue used num-cores as an example, but should work just as well
# with make-options
my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc);
{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is ($app->context()->getOption('num-cores'), 8, 'No cmdline option leaves num-cores value alone');

    is (scalar @moduleList, 4, 'Right number of modules');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[0]->getOption('make-options'), '-j4', 'make-options base value proper pre-override');

    is ($moduleList[3]->name(), 'module2', 'mod list[3] == module2');
    is ($moduleList[3]->getOption('make-options'), '-j 8', 'module-override make-options proper pre-override');
}

# We can't seem to assign -j3 as Getopt::Long will try to understand the option
# and fail
push @args, '--make-options', 'j3';

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is ($app->context()->getOption('num-cores'), 8, 'No cmdline option leaves num-cores value alone');

    is (scalar @moduleList, 4, 'Right number of modules');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[0]->getOption('make-options'), 'j3', 'make-options base value proper post-override');

    # Policy discussion: Should command line options override *all* instances
    # of an option in kdesrc-buildrc? Historically the answer has deliberately
    # been yes, so that's the behavior we enforce.
    is ($moduleList[3]->name(), 'module2', 'mod list[3] == module2');
    is ($moduleList[3]->getOption('make-options'), 'j3', 'module-override make-options proper post-override');
}

# Remove last two args and add another test of indirect option value setting

pop @args;
pop @args;
push @args, '--num-cores=5'; # 4 is default, 8 is in rc-file, use something different

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is ($app->context()->getOption('num-cores'), 5, 'Updated cmdline option changes global value');

    is (scalar @moduleList, 4, 'Right number of modules');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[0]->getOption('make-options'), '-j4', 'make-options base value proper post-override (indirect value)');

    is ($moduleList[3]->name(), 'module2', 'mod list[3] == module2');
    is ($moduleList[3]->getOption('make-options'), '-j 5', 'module-override make-options proper post-override (indirect value)');
}

done_testing();
