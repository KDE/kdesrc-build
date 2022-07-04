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

use warnings;
use v5.22;

use Mojo::Base -base, -signatures;

use Mojo::Server::Daemon;
use Mojo::Log;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojo::JSON qw(to_json j);
use Mojo::Util qw(dumper);

use ksb::BuildException;
use ksb::StatusView;
use ksb::Util;
use ksb::Debug;
use ksb::UserInterface::DependencyGraph;
use Mojo::Promise;

use IO::Handle; # For methods on event_stream file
use List::Util qw(max first);

has ua => sub { Mojo::UserAgent->new->inactivity_timeout(0) };
has ui => sub { ksb::StatusView->new() };
has 'app';

sub new
{
    my ($class, $app) = @_;

    my $self = $class->SUPER::new(
        app => $app,
        postbuild_msgs => [ ],
        log => Mojo::Log->new(level => 'warn')->context('[  tui  ]'),
    );

    # Mojo::UserAgent can be tied to a Mojolicious application server directly to
    # handle relative URLs, which is perfect for what we want. Making this
    # attachment will startup the Web server behind the scenes and allow $ua to
    # make HTTP requests.
    $self->ua->request_timeout(5);
    $self->ua->server->app($app);

    return $self;
}

sub _check_error {
    my $tx = shift;
    my $err = $tx->error or return $tx;

    # Most ksb::BuildException should be thrown as a json object that will be
    # decoded by ->catch handler
    my $err_block = $tx->res->json;
    die $err_block if $err_block;

    # But just in case, try to extract an error message.
    my $body = $tx->res->body // '';
    open my $fh, '<', \$body;
    my ($first_line) = <$fh> // '';
    $err->{message} .= "\n$first_line" if $first_line;
    die $err;
};

sub dumpDependencyTree
{
    my ($ua, $tree) = @_;

    my $errors = $tree->{errors} // {};
    my $errorCount = $errors->{errors} // 0;

    if ($errorCount != 0) {
        say "Unable to resolve dependencies, encountered $errorCount errors";
        return Mojo::Promise->new->reject(1);
    }

    my $data = $tree->{data};
    if (!defined($data)) {
        say "Unable to resolve dependencies, did not obtain (valid) results";
        return Mojo::Promise->new->reject(1);
    }

    return $ua->get_p('/modulesFromCommand')->then(sub {
        my $tx = _check_error(shift);
        my @modules = map { $_->{name} } @{$tx->result->json};

        my $err = ksb::UserInterface::DependencyGraph::printTrees(
           $data,
           @modules
        );

        return Mojo::Promise->new->reject(1)
            if $err;
        return 0;
    });
}

# Returns a promise chain to handle the "debug and show some output but don't
# actually build anything" use case.
sub _runModeDebug
{
    my $self = shift;
    my $app  = $self->app;
    my $ua   = $self->ua;
    my %debugFlags = %{$app->ksb->{debugFlags}};
    my $log  = $self->{log};

    $log->trace("Run mode: DEBUG");

    if ($debugFlags{'dependency-tree'}) {
        $log->debug("Dumping dependency tree");

        return $ua->get_p('/moduleGraph')->then(sub {
            my $tx = _check_error(shift);
            my $tree = $tx->result->json;
            return dumpDependencyTree($ua, $tree);
        });
    }
    elsif ($debugFlags{'list-build'} || $debugFlags{'print-modules'}) {
        $log->debug("Listing modules to build");

        return $ua->get_p('/modules')->then(sub {
            my $tx = _check_error(shift);
            my @modules = @{$tx->result->json};
            say $_ foreach @modules;
            return 0;
        });
    }

    # Bail early
    return Mojo::Promise->new->reject('Told to debug for no reason');
}

# Monitors events from the /events endpoint and blocks until the websocket
# fails or the build_done event is received.
#
# Returns the shell-style result of the overall build.
sub _handleBuildEvents ($self, $module_failures_ref)
{
    my $ui = $self->ui;
    my $ua = $self->ua;
    my $app = $self->app;
    my $log = $self->{log};

    # We track the build using a JSON-based event stream which is published as
    # an HTTP resource using Mojolicious, and which we can repeatedly poll
    # until the server is complete.
    # We need to return a promise which  ultimately resolves to the exit status
    # of the build.

    # Open a file to log the event stream
    my $ctx = $app->context();
    my $dest = pretending()
        ? '/dev/null'
        : $ctx->getLogDirFor($ctx) . '/event-stream';
    open my $event_stream, '>', $dest
        or croak_internal("Unable to open event log $!");
    $event_stream->say("["); # Try to make it valid JSON syntax

    my $build_promise = $ua->get_p('/build-plan')->then(sub ($tx) {
        $tx = _check_error($tx);

        my $eventListRef = $tx->res->json or croak_internal("Unable to get build plan!");
        $ui->notifyEvent($eventListRef->[0]);

        $log->trace("Build plan received from server");
        $event_stream->say(to_json($eventListRef->[0]));

        return 1; # Boolean to proceed with build
    });

    $self->{build_promise} = $build_promise; # ensure lifetime extends after this fn

    # Sub for handling get_p promise responses. Needs a name so we can refer back to it
    # from within itself.
    my $ev_handler;
    my $numHandled = 0;
    my $done_promise = Mojo::Promise->new;

    $ev_handler = sub ($ev_tx) {
        $ev_tx = _check_error($ev_tx);
        my $eventListRef = $ev_tx->res->json
            or croak_internal("Unable to get event list!");

        if (!scalar @{$eventListRef}) {
            # No changes since we last checked
            $log->trace("No changes to build after handling $numHandled events, waiting");
            return Mojo::Promise->timer(0.3)->then(sub {
                $log->trace("Checking again for events");
                $ua->get_p('/event-list' => form => { since => $numHandled })
                ->then($ev_handler);
            });
        }

        $log->trace("Received", scalar @{$eventListRef}, "events");

        my $done = 0;
        foreach my $modRef (@{$eventListRef}) {
            # Update the U/I
            eval {
                $ui->notifyEvent($modRef);
                $numHandled++;
                $event_stream->say(', ' . to_json($modRef))
                    unless $modRef->{event} eq 'phase_progress';
                $log->trace("Handled event $numHandled");
            };

            if ($@) {
                $log->error("Ran into an awful error! $@");
                $done_promise->reject($@);
            }

            # See ksb::StatusMonitor for where events defined
            if ($modRef->{event} eq 'phase_completed') {
                my $results = $modRef->{phase_completed};
                push @{$module_failures_ref}, $results
                    if $results->{result} eq 'error';
            } elsif ($modRef->{event} eq 'build_done') {
                $done = 1; # so we don't loop again
                $done_promise->resolve(scalar @{$module_failures_ref});
                delete $self->{build_promise};
            } elsif ($modRef->{event} eq 'new_postbuild_message') {
                # Just hold on to these messages until the end
                my $module_name = $modRef->{new_postbuild_message}->{module};
                my $module_msgs = first { $_->{name} eq $module_name } @{$self->{postbuild_msgs}};
                if (!$module_msgs) {
                    $module_msgs = { name => $module_name, msgs => [ ] };
                    push @{$self->{postbuild_msgs}}, $module_msgs;
                }

                push @{$module_msgs->{msgs}}, $modRef->{new_postbuild_message}->{message};
            }
        } # foreach

        # We've handled all events
        if (!$done) {
            # form => formats the HTTP GET param with a query string
            return $ua->get_p('/event-list' => form => { since => $numHandled })->then($ev_handler);
        } else {
            return $done_promise; # this promise has the results to proceed with
        }
    };

    # Kick off the initial event handler
    $build_promise = $build_promise->then(sub ($proceed) {
        croak_internal("Something went wrong with build plan?")
            unless $proceed;

        return $ua->get_p('/event-list')->then($ev_handler);
    })->finally(sub {
        $event_stream->say("]");
        $event_stream->close();

        # Check for post-build messages and list them here
        for my $module_msgs (@{$self->{postbuild_msgs}}) {
            my $module_name = $module_msgs->{name};
            my @msgs = @{$module_msgs->{msgs}};

            warning("\ny[Important notification for b[$module_name]:");
            warning("    $_") foreach @msgs;
        }

        my $logdir = $ctx->getLogDir();
        note ("Your logs are saved in file://y[$logdir]");
    });

    return $build_promise
}

# Causes the build server to begin the build. You can then use /events endpoint
# to track progress.
#
# Return value is:
#   1 if the build successfully started,
#   0 if the build started but there is nothing to do.
sub _runModeBuild ($self)
{
    $self->app->log->trace("Run mode: BUILD");

    # Kick off the build. This needs to be a non-blocking call because
    # Mojo::UserAgent can maintain two different app servers behind the
    # scenes, one for 'blocking' calls and one for 'non-blocking' calls.
    # These have different ports and we need to ensure that the eventual
    # $ctx->takeLock is called from the non-blocking server (which should
    # be primary).
    return $self->ua->post_p('/build')->then(sub ($tx) {
        # Ensure everything is OK before moving on.
        my $exceptionInfo = {
            exception_type => 'Internal',
            response       => $tx->res,
        };

        if (my $err = $tx->error) {
            # Possible if connection aborted
            if (!$tx->res->code) {
                $exceptionInfo->{message} = $err->{message} // 'Request to build server timed out!';
            } else {
                $exceptionInfo->{message} = "Error " . $err->{code} . ': ' . $err->{message};
            }

            die $exceptionInfo;
        }

        # Success but nothing to do.
        if ($tx->result->code == 204) {
            return 0;
        }

        # No issues? We'll leave things alone and the build will continue
        # until stopped for other reasons.
        return 1; # Continue the build
    });
}

# Just a giant huge promise handler that actually processes U/I events and
# keeps the TTY up to date. Note the TTY-specific stuff is actually itself
# buried in a separate class for now.
sub start
{
    my $self = shift;

    my $ua = $self->ua;
    my $app = $self->app;
    my $log = $self->{log};
    my $result = 0; # notes errors from module builds or internal errors

    my @module_failures;

    $log->trace("Sending test msg to backend");
    # This call just reads an option from the BuildContext as a sanity check
    $ua->get_p('/context/options/pretend')->then(sub {
        my $tx = shift;
        _check_error($tx);

        # If we get here things are mostly working?
        my $selectorsRef = $app->{ksb_state}->{selectors};

        # We need to specifically ask for all modules if we're not passing a
        # specific list of modules to build.
        my $headers = { };
        $headers->{'X-BuildAllModules'} = 1 unless @{$selectorsRef};

        $log->trace("Test msg success, sending selectors to build");
        # Tell the backend which modules to build.
        return $ua->post_p('/modules', $headers, json => $selectorsRef);
    })->then(sub {
        my $tx = shift;
        _check_error($tx);

        my $result = eval { $tx->result->json->[0]; };
        $log->trace("Selectors sent to backend, $result");

        # We've received a successful response from the backend that it's able to
        # build the requested modules, so proceed as appropriate based on the run mode
        # the user has requested.

        return $self->_runModeDebug()
            if (%{$app->ksb->{debugFlags} // 0});

        $log->trace("Building through run mode build");
        return $self->_runModeBuild();
    })->then(sub ($continueBuild) {
        $log->debug("Ready to build, should we continue? ", $continueBuild);

        if ($continueBuild) {
            $log->trace("Handling build events");
            # Install event monitoring and wait until the build is done
            return $self->_handleBuildEvents(\@module_failures);
        } else {
            return $result = 0; # Done
        }
    })->then(sub ($buildResult) {
        # Build done, value comes from runMode promise above
        $result ||= $buildResult;
        $log->debug("Chosen run mode complete, result (0 == success): $result");
    })->catch(sub {
        my $err = shift;
        # Catches all errors in any of the prior promises

        if (ref $err eq 'HASH') {
            # JSON response decoded to a hashref, or a result thrown by a
            # rejected promise
            say STDERR "Error encountered during build:"
                if ($err->{exception_type} // '') eq 'Internal';
            say STDERR $err->{message};
            say STDERR $err->{response}->body
                if $err->{response};
            $log->error("Recorded an error ", $err->{message});
        }
        else {
            say STDERR "Caught an error: $err";
            $log->error("Recorded an error $err");
        }

        $result = 1; # error
    })->wait;

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
