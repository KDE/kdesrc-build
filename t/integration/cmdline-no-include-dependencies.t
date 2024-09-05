# SPDX-FileCopyrightText: 2019, 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Verify that --no-include-dependencies is recognized and results
# in right value.

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

my @args = qw(--pretend --rc-file t/integration/fixtures/sample-rc/kdesrc-buildrc-with-deps --no-include-dependencies setmod1 setmod3);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[2] == setmod3');
}

{
    push @args, '--ignore-modules', 'setmod2';
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies+ignore-modules)');
    is ($moduleList[0]->name(), 'setmod1', 'mod list[0] == setmod1');
    is ($moduleList[1]->name(), 'setmod3', 'mod list[1] == setmod3');
}

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
