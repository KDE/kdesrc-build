# SPDX-FileCopyrightText: 2022 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Test that LoggedSubprocess works (and works reentrantly no less)

use ksb;
use Test::More;

use File::Temp qw(tempdir);
use POSIX;
use File::Basename;

use ksb::Module;
use ksb::BuildContext;
use ksb::BuildSystem;
use ksb::Util::LoggedSubprocess;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

my $ctx = ksb::BuildContext->new;
my $m   = ksb::Module->new($ctx, 'test');

ok($ctx, 'BuildContext setup');
ok($m,   'ksb::Module setup');
is($m->name(), 'test', 'ksb::Module has a name');

my $tmp = tempdir(CLEANUP => 1);
$ctx->setOption('log-dir', "$tmp/kdesrc-build-test");

my $cmd = ksb::Util::LoggedSubprocess->new
    ->module($m)
    ->log_to('test-suite-1')
    ->set_command(['perl', '-E', 'my $x = 2 + 2; say qq($x);' ])
    ->chdir_to($tmp)
    ->announcer(sub ($mod) {
        say("Calculating stuff for $mod");
    })
    ;

isa_ok($cmd, 'ksb::Util::LoggedSubprocess', 'got the right type of cmd');

my $output;
my $prog1Exit;
my $prog2Exit;

$cmd->on(child_output => sub ($cmd, $line) {
    chomp($output = $line);
});

my $promise = $cmd->start->then(sub ($exitcode) {
    $prog1Exit = $exitcode;

    # Create a second LoggedSubprocess while the first one is still alive, even
    # though it is finished.
    my $cmd2 = ksb::Util::LoggedSubprocess->new
        ->module($m)
        ->log_to('test-suite-2')
        ->set_command(['perl', '-E', 'my $x = 4 + 4; say qq(here for stdout); die qq(hello);' ])
        ->chdir_to($tmp)
        ;
    my $promise2 = $cmd2->start->then(sub ($exit2) {
        $prog2Exit = $exit2;
    });

    return $promise2; # Resolve to another promise that requires resolution
});

isa_ok($promise, 'Mojo::Promise', 'A promise should be a promise!');
$promise->wait;

is($output, '4', 'Interior child command successfully completed');
is($prog1Exit, 0, 'Program 1 exited correctly');
isnt($prog2Exit, 0, 'Program 2 failed');

ok(-d "$tmp/kdesrc-build-test/latest/test", "Test module had a 'latest' dir setup");
ok(-l "$tmp/kdesrc-build-test/latest-by-phase/test/test-suite-1.log", "Test suite 1 phase log created");
ok(-l "$tmp/kdesrc-build-test/latest-by-phase/test/test-suite-2.log", "Test suite 2 phase log created");

chdir('/'); # ensure we're out of the test directory

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
