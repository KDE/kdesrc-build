#!/usr/bin/perl
# Test suite for kdesrc-build. If you encounter tests that fail on your
# correctly-configured system please let myself or the kde-buildsystem mailing
# list know so I can fix and/or workaround. -mpyne
#
# Copyright © 2008 - 2011 Michael Pyne. <mpyne@kde.org>
# Home page: http://kdesrc-build.kde.org/
#
# You may use, alter, and redistribute this software under the terms
# of the GNU General Public License, v2 (or any later version).

use strict;
use warnings;

package test; # Tells kdesrc-build not to run
require 'kdesrc-build';

# Must come after require kdesrc-build
use Test::More qw(no_plan);

# From kdesrc-build
our %package_opts;
our %ENV_VARS;

my %more_package_opts = (
  'qt-copy' => {
      'cxxflags' => '-pipe -march=i386',
      'configure-flags' => '-fast',
  },

  'kdelibs' => {
      'cmake-options' => '-DTEST=TRUE',
      'unused' => 0,
  },

  'kdesdk' => { },

  'kdesupport' => { },

  'phonon' => { },

  'playground/libs' => { },

  'KDE/kdelibs' => {
      'cmake-options' => '-DTEST=TRUE',
  },

  'test' => {
      'source-dir' => '~/testsrc',
      'module-base-path' => 'KDE/KDE/test',
      'set-env' => { 'MOIN'=>'2' },
  },
);

for my $key (keys %more_package_opts) {
    $package_opts{$key} = $more_package_opts{$key};
}

# If using set-env, it is handled by the handle_set_env routine, so the
# value should be the space separated VAR and VALUE.
set_option('global', 'set-env', 'TESTY_MCTEST yes');
set_option('global', 'cxxflags', '-g -O0');
set_option('global', 'cmake-options', '-DCMAKE_BUILD_TYPE=RelWithDebInfo');
set_option('global', 'svn-server', 'svn+ssh://svn.kde.org/home/kde');
set_option('global', 'configure-flags', '-fast -dbus');
set_option('global', '#configure-flags', '-fast -dbus');
set_option('global', 'source-dir', '/kdesvn/src');
set_option('global', '#unused', '1');
set_option('global', 'branch', '4.3');

# Commence testing proper
is(get_option('qt-copy', 'cxxflags'), '-pipe -march=i386', 'qt-copy cxxflags handling');
is(get_option('qt-copy', 'configure-flags'), '-fast', 'qt-copy configure-flags handling');
is(get_option('kdelibs', 'unused'), 1, 'Test normal sticky option');
like(get_option('kdelibs', 'cmake-options'), qr/^-DCMAKE_BUILD_TYPE=RelWithDebInfo/, 'kdelibs cmake-options appending');
like(get_option('kdelibs', 'cmake-options'), qr/-DTEST=TRUE$/, 'kdelibs options appending');
is(get_option('test', 'branch', 'module'), undef, 'get_option limit to module level');

set_option('kdelibs', 'branch', 'trunk');
is(svn_module_url('kdelibs'), 'svn+ssh://svn.kde.org/home/kde/trunk/KDE/kdelibs', 'KDE module trunk');

set_option('kdelibs', 'tag', '4.1.3');
set_option('kdelibs', 'branch', '4.2');
like(handle_branch_tag_option('kdelibs', 'tags'), qr(/tags/KDE/4.1.3/kdelibs$), 'KDE module tag preferred to branch');

set_option('kdelibs', 'tag', '');
like(handle_branch_tag_option('kdelibs', 'branches'), qr(/branches/KDE/4.2/kdelibs$), 'KDE module branch');

set_option('kdesupport', 'branch', 'trunk');
is(svn_module_url('kdesupport'), 'svn+ssh://svn.kde.org/home/kde/trunk/kdesupport', 'non-KDE module trunk');

# Issue reported by dfaure 2011-02-06, where the kdesupport-branch was not being
# obeyed when global-branch was set to 4.6, so somehow kdesrc-build wanted a
# mystical kdesupport-from-4.6 branch
set_option('kdesupport', 'branch', 'master');
set_option('kdesupport', 'prefix', '/d/kde/inst/kdesupport-for-4.6');
set_option('global', 'branch', '4.6');
is(svn_module_url('kdesupport'), 'svn+ssh://svn.kde.org/home/kde/branches/kdesupport/master', 'kdesupport-for-$foo with local branch override');

set_option('kdesupport', 'tag', 'kdesupport-for-4.2');
like(handle_branch_tag_option('kdesupport', 'tags'), qr(/tags/kdesupport-for-4.2$), 'non-KDE module tag (no name appended)');
is(svn_module_url('kdesupport'), 'svn+ssh://svn.kde.org/home/kde/tags/kdesupport-for-4.2', 'non-KDE module tag (no name; entire URL)');

set_option('phonon', 'branch', '4.2');
is(svn_module_url('phonon'), 'svn+ssh://svn.kde.org/home/kde/branches/phonon/4.2', 'non-KDE module branch (no name appended)');

set_option('phonon', 'branch', '');
set_option('phonon', 'module-base-path', 'tags/phonon/4.2');
is(svn_module_url('phonon'), 'svn+ssh://svn.kde.org/home/kde/tags/phonon/4.2', 'module-base-path');

my @result1 = qw/a=b g f/;
my @quoted_result = ('a=b g f', 'e', 'c=d', 'bless');
is_deeply([ split_quoted_on_whitespace('"a=b g f" "e" c=d bless') ], \@quoted_result, "split_quoted_on_whitespace quotes and spaces");
is_deeply([ split_quoted_on_whitespace('a=b g f') ], \@result1, 'split_quoted_on_whitespace space, no quotes');
is_deeply([ split_quoted_on_whitespace(' a=b g f') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading whitespace');
is_deeply([ split_quoted_on_whitespace('a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, trailing whitespace');
is_deeply([ split_quoted_on_whitespace(' a=b g f ') ], \@result1, 'split_quoted_on_whitespace space no quotes, leading and trailing whitespace');

like(get_svn_info('kdesupport', 'URL'), qr/svn\.kde\.org/, 'svn-info output (url)');
like(get_svn_info('kdesupport', 'Revision'), qr/^\d+$/, 'svn-info output (revision)');

# Test get_subdir_path
is(get_subdir_path('kdelibs', 'build-dir'), "/kdesvn/src/build", 'build-dir subdir path rel');
is(get_subdir_path('kdelibs', 'log-dir'), "/kdesvn/src/log", 'log-dir subdir path rel');
set_option('kdelibs', 'build-dir', '/tmp');
is(get_subdir_path('kdelibs', 'build-dir'), "/tmp", 'build-dir subdir path abs');
set_option('kdelibs', 'build-dir', '~/tmp/build');
is(get_subdir_path('kdelibs', 'build-dir'), "$ENV{HOME}/tmp/build", 'build-dir subdir path abs');

# correct log dir
print "Creating log directory:\n";
setup_logging_subsystem();
my $logdir = get_log_dir('playground/libs');
ok(log_command('playground/libs', 'touch', ['touch', '/tmp/tmp.tmp']) == 0, 'creating temp file');
ok(-e "$ENV{HOME}/kde4/log/latest/playground/libs/touch.log", 'correct playground/libs log path');
unlink('/tmp/tmp.tmp');

# Trunk and non-trunk l10n
is(svn_module_url('l10n-kde4'), 'svn+ssh://svn.kde.org/home/kde/branches/stable/l10n-kde4', 'stable l10n path');
set_option('global', 'branch', 'trunk');
is(svn_module_url('l10n-kde4'), 'svn+ssh://svn.kde.org/home/kde/trunk/l10n-kde4', 'trunk l10n path');

is(get_source_dir('test'), "$ENV{HOME}/testsrc", 'separate source-dir for modules');
update_module_environment('test');
is($ENV_VARS{'TESTY_MCTEST'}, 'yes', 'setting global set-env for modules');
is($ENV_VARS{'MOIN'}, '2', 'setting module set-env for modules');

# Ensure svn URL hierarchy is correct
like(svn_module_url('test'), qr{/home/kde/KDE/KDE/test$}, 'svn_module_url prefer module specific to global');
set_option('test', 'override-url', 'svn://annono');
is(svn_module_url('test'), 'svn://annono', 'testing override-url');

my @modules = process_arguments('--test,override-url=svn://ann');
is(svn_module_url('test'), 'svn://ann', 'testing process_arguments module options');
is(scalar @modules, 0, 'testing process_arguments return value for no passed module names');

@modules = qw/qt-copy kdelibs kdebase/;
my @Modules = map { Module->new($_) } (@modules);
is_deeply([process_arguments(@modules)], \@Modules, 'testing process_arguments return value for passed module names');

$_->filterOutPhase('update') foreach @Modules;
is_deeply([process_arguments(@modules, '--no-src')], \@Modules, 'testing --no-src phase updating');

$_->filterOutPhase('build') foreach @Modules;
is_deeply([process_arguments(@modules, '--no-build', '--no-src')], \@Modules, 'testing --no-src and --no-build phase updating');
