use 5.014;
use strict;
use warnings;

# Verify that --no-include-dependencies is recognized and results
# in right value.

use Test::More;

use ksb::Application;
use ksb::Module;

# Redefine ksb::Application::_resolveModuleDependencies to avoid requiring metadata
# module.
package ksb::Application {
    no warnings 'redefine';

    sub _resolveModuleDependencyGraph {
        my $self = shift;
        my @modules = @_;

        my $newModule = ksb::Module->new($self->{context}, 'setmod2');

        my $graph = {
            'setmod1' => {
                votes => {
                    'setmod2' => 1,
                    'setmod3' => 1
                },
                build => 1,
                module => $modules[0]
            },
            'setmod2' => {
                votes => {
                    'setmod3' => 1
                },
                build => !!$self->context()->getOption('include-dependencies'),
                module => $newModule
            },
            'setmod3' => {
                votes => {},
                build => 1,
                module => $modules[1]
            }
        };

        my $result = {
            graph => $graph
        };

        return $result;
    }
};

my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc-with-deps --no-include-dependencies setmod1 setmod3);

{
    my $app = ksb::Application->new;
    my @selectors = $app->establishContext(@args);
    my $workload = $app->modulesFromSelectors(@selectors);
    $app->setModulesToProcess($workload);
    my @moduleList = $app->modules();

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[2] == setmod3');
}

{
    push @args, '--ignore-modules', 'setmod2';

    my $app = ksb::Application->new;
    my @selectors = $app->establishContext(@args);
    my $workload = $app->modulesFromSelectors(@selectors);
    $app->setModulesToProcess($workload);
    my @moduleList = $app->modules();

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies+ignore-modules)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[1] == setmod3');
}

done_testing();
