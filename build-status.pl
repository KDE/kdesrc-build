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
use List::Util qw(min max);

my $run = $ENV{XDG_RUNTIME_DIR} // '/tmp';
my $server_url_path = "$run/kdesrc-build-status-server";
open my $server_url_fh, '<', $server_url_path;

# remove any trailing \n
chomp(my $path = <$server_url_fh>);
close $server_url_fh;

# Used by update_output
my %num_phases_todo;
my %num_phases_done;
my %current_module_for_phase;
my $longest_module_name = '';
my %module_failures;

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
                if ($modRef->{event} eq 'phase_started') {
                    my $module = $modRef->{phase_started}->{module};
                    my $phase  = $modRef->{phase_started}->{phase};

                    $current_module_for_phase{$phase} = $module;

                    update_output();
                }
                elsif ($modRef->{event} eq 'phase_completed') {
                    my $mr = $modRef->{phase_completed};
                    my $phase = $mr->{phase};
                    $module_failures{$mr->{module}} = $phase
                        if ($mr->{result} eq 'error');

                    $num_phases_done{$phase} //= 0;
                    $num_phases_done{$phase}++;
                    $current_module_for_phase{$phase} =
                        ($num_phases_todo{$phase} == $num_phases_done{$phase})
                            ? '---' : '';

                    update_output();
                }
                elsif ($modRef->{event} eq 'build_plan') {
                    my @modules = @{$modRef->{build_plan}};

                    foreach my $m (@modules) {
                        $longest_module_name = $m
                            if length($m) > length($longest_module_name);

                        foreach my $phase (@{$m->{phases}}) {
                            $num_phases_todo{$phase} //= 0;
                            $num_phases_todo{$phase}++;
                        }
                    }
                }
                elsif ($modRef->{event} eq 'build_done') {
                    print "\n";

                    while (my ($module, $phase) = each %module_failures) {
                        say "$module failed to $phase";
                    }

                    $ws->finish;
                }
                elsif ($modRef->{event} eq 'log_entries') {
                    my @entries = @{$modRef->{log_entries}->{entries}};
                    my ($module, $phase) = @{$modRef->{log_entries}}{qw(module phase)};
                    foreach my $entry (@entries) {
                        # say "$module: $phase: $entry";
                    }
                }
                else {
                    say "Unhandled event ", $modRef->{event};
                }
            }
        });

        return $promise;
    })->wait;

exit 0 unless %module_failures;
exit 1;

sub phase_progress_string
{
    my @phases = @_;
    my $result = '';
    my $base   = '';

    foreach my $phase (@phases) {
        my $cur = $num_phases_done{$phase} // 0;
        my $max = $num_phases_todo{$phase}
            or die "No phase $phase";

        my $strWidth = length("$max");
        my $progress = sprintf("%0*s/$max", $strWidth, $cur);

        $result .= "$base$phase [$progress]";
        $base = ' ';
    }

    return $result;
}

sub current_module_status
{
    my @phases = @_;
    my $result = '';
    my $base   = '';

    foreach my $phase (@phases) {
        my $curModule = $current_module_for_phase{$phase} // '???';

        $result .= "$base$phase: $curModule";
        $base = ' ';
    }

    return $result;
}

sub get_min_output_width
{
    my @phases = qw(update build);
    my %temp_current = %current_module_for_phase;

    # fake that the worst-case module is set and find resultant length
    $current_module_for_phase{$_} = $longest_module_name
        foreach @phases;

    my $str = phase_progress_string(@phases) . " " . current_module_status(@phases);

    %current_module_for_phase = %temp_current;

    return length($str);
}

sub update_output
{
    state $term_width = get_terminal_size();
    state $min_width  = get_min_output_width();

    my @phases = qw(update build);
    my $progress = phase_progress_string(@phases);
    my $current_modules = current_module_status(@phases);

    my $width = $term_width / 2 - 1;
    my $msg;

    if ($min_width >= ($term_width - 12)) {
        $msg = "$progress $current_modules";
    } else {
        my $max_prog_width = ($term_width - $min_width) - 2;
        my $num_all_done  = min(@num_phases_done{@phases});
        my $num_some_done = max(@num_phases_done{@phases}, 0);
        my $max_todo      = max(@num_phases_todo{@phases}, 1);

        my $width = $max_prog_width * $num_all_done / $max_todo;
        # Leave at least one empty space if we're not fully done
        $width-- if ($width == $max_prog_width && $num_all_done < $max_todo);

        my $bar = ('=' x $width);

        if ($num_some_done > $num_all_done) {
            $width = $max_prog_width * $num_some_done / $max_todo;
            $bar .= ('.' x ($width - length ($bar)));
        }

        $msg = sprintf("%s [%*s] %s", $progress, -$max_prog_width, $bar, $current_modules);
    }

    # Give escape sequence to return to column 1 and clear the entire line
    # Then print message and return to column 1 again in case somewhere else
    # uses the tty.
    print "\e[1G\e[K$msg\e[1G";
    STDOUT->flush;
}

sub get_terminal_size
{
    my $width;
    chomp($width = `tput cols`);
    $width //= $ENV{COLUMNS} // 80;

    return int($width);
}
