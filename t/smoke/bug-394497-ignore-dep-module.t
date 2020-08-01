use 5.014;
use strict;
use warnings;

# Verify that --ignore-modules works for modules that would be included with
# --include-dependencies in effect.
# See bug 394497 -- https://bugs.kde.org/show_bug.cgi?id=394497

use Test::More;

use ksb::Application;
use ksb::Module;

# Redefine ksb::Application::_resolveModuleDependencies to avoid requiring metadata
# module.
package ksb::Application {
    no warnings 'redefine';
    our $IGNORE_MOD2 = 0;

    sub _resolveModuleDependencyGraph {
        my $self = shift;
        my @modules = @_;

        my $newModule = ksb::Module->new($self->{context}, 'setmod2');

        my $graph = { };

        # Construct graph manually based on real module list
        foreach my $module (@modules) {
            my $name = $module->name();
            $graph->{$name} = {
                votes => { },
                build => 1,
                module => $module,
            };
        }

        if (exists $graph->{setmod1}) {
            $graph->{setmod1}->{votes} = {
                'setmod2' => 1,
                'setmod3' => 1
            };

            # setmod1 is only user of setmod2
            if (!exists $graph->{setmod2}) {
                $graph->{setmod2} = {
                    votes => {
                        'setmod3' => 1
                    },
                    build => !$IGNORE_MOD2,
                    module => $newModule,
                };
            }
        }

        return {
            graph => $graph
        };
    }
};

my @args = qw(--pretend --rc-file t/data/sample-rc/kdesrc-buildrc --include-dependencies setmod1 setmod3);

{
    my $app = ksb::Application::newFromCmdline(@args);
    my @moduleList = $app->modules();

    is (scalar @moduleList, 3, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod2', 'mod list[1] == setmod2');
    is ($moduleList[2]->name(), 'setmod3', 'mod list[2] == setmod3');
}

{
    push @args, '--ignore-modules', 'setmod2';

    $ksb::Application::IGNORE_MOD2 = 1;
    my $app = ksb::Application::newFromCmdline(@args);
    my @moduleList = $app->modules();

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies+ignore-modules)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[1] == setmod3');
}

# Verify that --ignore-modules on a moduleset name filters out the whole set
{
    @args = (@args[0..2], qw(--ignore-modules set1));

    my $app = ksb::Application::newFromCmdline(@args);
    my @moduleList = $app->modules();

    is (scalar @moduleList, 1, 'Right number of modules (ignore module-set)');
    is ($moduleList[0]->name(), 'module2', 'mod list[0] == module2');
}

done_testing();
