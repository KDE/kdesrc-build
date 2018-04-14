#!/usr/bin/env perl

# A simplistic client to test out status reporting from within kdesrc-build

# To use, run this client while kdesrc-build is running (kdesrc-build from the
# 'make_it_mojo' git branch).  This script will connect to kdesrc-build's
# web server every couple of seconds and pull information on a random module.
#
# This isn't intended for actual use, but as a driver to verify the
# kdesrc-build end and to help with writing a GUI client when that time comes.
#
# As with the kdesrc-build support, the Perl Mojolicious module is required for
# this, although it doesn't require any non-core dependencies itself and is
# very small for what it delivers, so that should hopefully not be very
# problematic.

use v5.14;
use strict;
use autodie;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);

my $run = $ENV{XDG_RUNTIME_DIR} // '/tmp';
my $server_url_path = "$run/kdesrc-build-status-server";
open my $server_url_fh, '<', $server_url_path;

my $path = <$server_url_fh>;
chomp $path; # remove any trailing \n
close $server_url_fh;

my $ua = Mojo::UserAgent->new;
my $base = Mojo::URL->new($path);
my $base_ws = $base->clone->scheme('ws');
my $seen_srv = 0; # used to ignore errors until after first success

# Lower timeouts since these shouldn't take long on a local machine.
$ua->connect_timeout(15);
$ua->request_timeout(20);
$ua->inactivity_timeout(0); # But disable inactivity timeout to allow long-poll
$ua->max_redirects(0);
$ua->max_connections(0); # disable keepalive to avoid server closing connection on us
$ua->max_response_size(16384);

$ua->websocket_p($base_ws->clone->path("ok"))
    ->then(sub {
        my $ws = shift;
        my $promise = Mojo::Promise->new;

        $ws->on(finish => sub { $promise->resolve });
        $ws->on(json => sub {
            my ($ws, $resultRef) = @_;
            foreach my $modRef (@{$resultRef}) {
                if ($modRef->{event} eq 'phase_completed') {
                    my $mr = $modRef->{phase_completed};
                    say $mr->{module}, " done with phase ", $mr->{phase}, ":",
                        $mr->{result};
                }
                elsif ($modRef->{event} eq 'build_plan') {
                    my @modules = @{$modRef->{build_plan}};
                    say "Received build plan";
                    foreach my $m (@modules) {
                        say "Will build ", $m->{name}, " with phases: ", join(', ', @{$m->{phases}});
                    }
                }
                elsif ($modRef->{event} eq 'build_done') {
                    say "BUILD DONE";
                }
                elsif ($modRef->{event} eq 'log_entries') {
                    my @entries = @{$modRef->{log_entries}->{entries}};
                    my ($module, $phase) = @{$modRef->{log_entries}}{qw(module phase)};
                    foreach my $entry (@entries) {
                        say "$module: $phase: $entry";
                    }
                }
                else {
                    say "Unhandled event ", $modRef->{event};
                }
            }
        });

        return $promise;
    })
    ->then(sub {
            say "Connection closed";
        })
    ->wait;
