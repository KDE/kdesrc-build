# Verify that --ignore-modules works for modules that would be included with
# --include-dependencies in effect.
# See bug 394497 -- https://bugs.kde.org/show_bug.cgi?id=394497

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;
use ksb::Module;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

# Redefine ksb::Application::_resolveModuleDependencies to avoid requiring metadata
# module.
package ksb::Application {
    no warnings 'redefine';

    sub _resolveModuleDependencyGraph {
        my $self = shift;
        my @modules = @_;

        my $newModule = $self->{module_factory}->('setmod2');

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
                    build => 1,
                    module => $newModule,
                };
            }
        }

        return {
            graph => $graph
        };
    }
};

my @args = qw(--pretend --rc-file t/integration/fixtures/sample-rc/kdesrc-buildrc --include-dependencies setmod1 setmod3);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 3, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod2', 'mod list[1] == setmod2');
    is ($moduleList[2]->name(), 'setmod3', 'mod list[2] == setmod3');
}

{
    push @args, '--ignore-modules', 'setmod2';
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies+ignore-modules)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[1] == setmod3');
}

# Verify that --include-dependencies on a moduleset name filters out the whole set
{
    @args = (@args[0..2], qw(--ignore-modules set1));

    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 1, 'Right number of modules (ignore module-set)');
    is ($moduleList[0]->name(), 'module2', 'mod list[0] == module2');
}

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
