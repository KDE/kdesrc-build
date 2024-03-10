# SPDX-FileCopyrightText: 2018, 2020, 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Test use of --set-module-option-value

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

my $app = ksb::Application->new(qw(
    --pretend --rc-file t/integration/fixtures/sample-rc/kdesrc-buildrc
    --set-module-option-value), 'module2,tag,fake-tag10',
   '--set-module-option-value', 'setmod2,tag,tag-setmod10');
my @moduleList = @{$app->{modules}};

is(scalar @moduleList, 4, 'Right number of modules');

my ($module) = grep { "$_" eq 'module2' } @moduleList;
my $scm = $module->scm();
my ($branch, $type) = $scm->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/fake-tag10', 'Right tag name');
is($type, 'tag', 'Result came back as a tag');

($module) = grep { "$_" eq 'setmod2' } @moduleList;
($branch, $type) = $module->scm()->_determinePreferredCheckoutSource();

is($branch, 'refs/tags/tag-setmod10', 'Right tag name (options block from cmdline)');
is($type, 'tag', 'cmdline options block came back as tag');

ok(!$module->isKDEProject(), 'setmod2 is *not* a "KDE" project');
is($module->fullProjectPath(), 'setmod2', 'fullProjectPath on non-KDE modules returns name');

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
