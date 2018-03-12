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
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json);

my $ua = Mojo::UserAgent->new;
my $base = Mojo::URL->new('http+unix://%2Ftmp%2Fkdesrc-build-uds/');
my $seen_srv = 0; # used to ignore errors until after first success

# Lower timeouts since these shouldn't take long on a local machine.
$ua->connect_timeout(15);
$ua->request_timeout(20);
$ua->max_redirects(0);
$ua->max_connections(0); # disable keepalive to avoid server closing connection on us
$ua->max_response_size(16384);

Mojo::IOLoop->recurring(2 => sub {
    # The 'delay' isn't chronological but step-based, this delays each step
    # until all the ones before have completed, passing the value passed into
    # the callback returned from delay->begin as the input to the step
    # happening next.
    # Each step can have multiple actions in parallel that must all complete
    # before moving to the next step, though that isn't used here.
    Mojo::IOLoop->delay(
        # step 1, get list of modules updated
        sub {
            my $delay = shift;

            # When the promise resolves, it will call the cb returned by begin
            $ua->get_p($base->clone->path('list'))
                ->then($delay->begin(0))
                ->catch(sub {
                    my $err = shift;
                    if ($seen_srv) {
                        say "Caught an error: $err";
                        Mojo::IOLoop->stop;
                    }
                });
        },
        # step 2, pick a module and get specifics on it
        sub {
            # promise resolved to $tx
            my ($delay, $tx) = @_;
            die "wrong tx type" unless $tx->isa('Mojo::Transaction');
            $seen_srv = 1; # any error will abort the script now

            my $res = $tx->result;
            if (!$res->is_success) {
                die "Received error ", $res->error->{code}, " msg ", $res->error->{message};
            }

            my @mods = @{decode_json($tx->result->body)};
            my $rand_mod = @mods[int(rand(scalar @mods))];
            my $end = $delay->begin(0);

            $ua->get_p($base->clone->path("status/$rand_mod"))
                ->then(sub {
                    my $tx = shift;
                    die $tx->error->{message} if $tx->error;
                    $end->($tx, $rand_mod);
                })
                ->catch(sub {
                    my $err = shift;
                    say "Caught an error in module responder: $err";
                    Mojo::IOLoop->stop;
                });
        },
        # step 3, show results of module chosen
        sub {
            # next promise resolved, with the tx and mod
            my ($delay, $tx, $mod) = @_;
            my $last_status = decode_json($tx->result->body)->{$mod};

            say "Last $mod update status: $last_status";
        },
    )->catch(sub {
        my $err = shift;
        say "Received connection error: $err";
        Mojo::IOLoop->stop if $seen_srv;
    });
});

Mojo::IOLoop->start;
