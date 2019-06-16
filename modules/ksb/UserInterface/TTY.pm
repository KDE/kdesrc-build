#!/usr/bin/env perl

package ksb::UserInterface::TTY 0.10;

=pod

=head1 NAME

ksb::UserInterface::TTY -- A command-line interface to the kdesrc-build backend

=head1 DESCRIPTION

This class is used to show a user interface for a kdesrc-build run at the
command line (as opposed to a browser-based or GUI interface).

Since the kdesrc-build backend is now meant to be headless and controlled via a
Web-style API set (powered by Mojolicious), this class manages the interaction
with that backend, also using Mojolicious to power the HTTP and WebSocket
requests necessary.

=head1 SYNOPSIS

    my $app = web::BackendServer->new(@ARGV);
    my $ui = ksb::UserInterface::TTY->new($app);
    exit $ui->start(); # Blocks! Returns a shell-style return code

=cut

use strict;
use warnings;
use 5.014;

use Mojo::Base -base;

use Mojo::Server::Daemon;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojo::JSON qw(to_json);

use ksb::BuildException;
use ksb::StatusView;
use ksb::Util;
use ksb::Debug;

use IO::Handle; # For methods on event_stream file
use List::Util qw(max);

has ua => sub { Mojo::UserAgent->new->inactivity_timeout(0) };
has ui => sub { ksb::StatusView->new() };
has 'app';

sub new
{
    my ($class, $app) = @_;

    my $self = $class->SUPER::new(app => $app);

    # Mojo::UserAgent can be tied to a Mojolicious application server directly to
    # handle relative URLs, which is perfect for what we want. Making this
    # attachment will startup the Web server behind the scenes and allow $ua to
    # make HTTP requests.
    $self->ua->server->app($app);
    $self->ua->server->app->log->level('fatal');

    return $self;
}

sub _check_error {
    my $tx = shift;
    my $err = $tx->error or return;
    my $body = $tx->res->body // '';
    open my $fh, '<', \$body;
    my ($first_line) = <$fh> // '';
    $err->{message} .= "\n$first_line" if $first_line;
    die $err;
};

# Just a giant huge promise handler that actually processes U/I events and
# keeps the TTY up to date. Note the TTY-specific stuff is actually itself
# buried in a separate class for now.
sub start
{
    my $self = shift;

    my $ui = $self->ui;
    my $ua = $self->ua;
    my $app = $self->app;
    my $result = 0; # notes errors from module builds or internal errors

    my @module_failures;

    # Open a file to log the event stream
    my $ctx = $app->context();
    my $separator = '  ';
    my $dest = pretending()
        ? '/dev/null'
        : $ctx->getLogDirFor($ctx) . '/event-stream';
    open my $event_stream, '>', $dest
        or croak_internal("Unable to open event log $!");
    $event_stream->say("["); # Try to make it valid JSON syntax

    # This call just reads an option from the BuildContext as a sanity check
    $ua->get_p('/context/options/pretend')->then(sub {
        my $tx = shift;
        _check_error($tx);

        # If we get here things are mostly working?
        my $selectorsRef = $app->{selectors};

        # We need to specifically ask for all modules if we're not passing a
        # specific list of modules to build.
        my $headers = { };
        $headers->{'X-BuildAllModules'} = 1 unless @{$selectorsRef};

        # Tell the backend which modules to build.
        return $ua->post_p('/modules', $headers, json => $selectorsRef);
    })->then(sub {
        my $tx = shift;
        _check_error($tx);

        # We've received a successful response from the backend that it's able to
        # build the requested modules, so proceed to setup the U/I and start the
        # build.

        return $ua->websocket_p('/events');
    })->then(sub {
        # Websocket Event handler
        my $ws = shift;
        my $everFailed = 0;
        my $stop_promise = Mojo::Promise->new;

        # Websockets seem to be inherently event-driven instead of simply
        # client/server.  So attach the event handlers and then return to the event
        # loop to await progress.
        $ws->on(json => sub {
            # This handler is called by the backend when there is something notable
            # to report
            my ($ws, $resultRef) = @_;
            foreach my $modRef (@{$resultRef}) {
                # Update the U/I
                eval {
                    $ui->notifyEvent($modRef);
                    $event_stream->say($separator . to_json($modRef));
                    $separator = ', ';
                };

                if ($@) {
                    $ws->finish;
                    $stop_promise->reject($@);
                }

                # See ksb::StatusMonitor for where events defined
                if ($modRef->{event} eq 'phase_completed') {
                    my $results = $modRef->{phase_completed};
                    push @module_failures, $results
                        if $results->{result} eq 'error';
                }

                if ($modRef->{event} eq 'build_done') {
                    # We've reported the build is complete, activate the promise
                    # holding things together. The value we pass is what is passed
                    # to the next promise handler.
                    $stop_promise->resolve(scalar @module_failures);
                }
            }
        });

        $ws->on(finish => sub {
            # Shouldn't happen in a normal build but it's probably possible
            $stop_promise->reject; # ignored if we resolved first
        });

        # Blocking call to kick off the build
        my $tx = $ua->post('/build');
        if (my $err = $tx->error) {
            $stop_promise->reject('Unable to start build: ' . $err->{message});
        }

        # Once we return here we'll wait in Mojolicious event loop for awhile until
        # the build is done, before moving into the promise handler below
        return $stop_promise;
    })->then(sub {
        # Build done, value comes from stop_promise->resolve above
        $result ||= shift;
    })->catch(sub {
        # Catches all errors in any of the prior promises
        my $err = shift;

        say "Error: ", $err->{code}, " ", $err->{message};

        # See if we made it to an rc-file
        my $ctx = $app->ksb->context();
        my $rcFile = $ctx ? $ctx->rcFile() // 'Unknown' : undef;
        say "Using configuration file found at $rcFile" if $rcFile;

        $result = 1; # error
    })->wait;

    $event_stream->say("]");
    $event_stream->close() or $result = 1;

    # _report_on_failures(@module_failures);

    return $result;
};

sub _report_on_failures
{
    my @failures = @_;
    my $max_width = max map { length ($_->{module}) } @failures;

    foreach my $mod (@failures) {
        my $module  = $mod->{module};
        my $phase   = $mod->{phase};
        my $log     = $mod->{error_file};
        my $padding = $max_width - length $module;

        $module .= (' ' x $padding); # Left-align
        $phase = 'setup buildsystem' if $phase eq 'buildsystem';

        error("b[*] r[b[$module] failed to b[$phase]");
        error("b[*]\tFind the log at file://$log") if $log;
    }
}

1;
