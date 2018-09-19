#!/usr/bin/env perl

package ksb::PromiseChain 0.10;

use Mojo::Base -base;
use Mojo::Promise;

has 'items'        => sub { return {} }; # nodes
has 'dependencies' => sub { return {} }; # edges

# Maps each queue to the last item entered in that queue for dependencies
# This imparts an implicit ordering. Maybe better to do it explicitly?
has 'last_queue_item' => sub { return {} };

=head1 NAME

PromiseChain - Map coderefs containing work to be done into a dependency order
using L<Mojo::Promise> to control the flow of execution.

=head1 SYNOPSIS

    my $deps = PromiseChain->new;

    $deps->addItem('job1/update', 'network-io', sub {
        my $ua = Mojo::UserAgent->new;
        $ua->get_p('https://www.kde.org/');
    });

    # A different queue, could run in parallel
    $deps->addItem('job1/build', 'cpu', sub {
        ... # Return a promise for long-running tasks!
    });

    # To properly order work, add a dependency from the build to the update,
    # now the update must complete for the build to start even if the queue is
    # free.
    $deps->addDep('job1/build', 'job1/update');

    # Implicitly is serialized to wait for job1/update since it
    # is in the same queue 'network-io'
    $deps->addItem('job2/update', 'network-io', sub {
        ... # Return a promise for long-running tasks!
    });

    my $all_promise = $deps->makePromiseChain;
    $all_promise->then(sub {
        # success
    })->catch(sub {
        # failure
    })->wait;

    # Won't reach this point until the full build is done, but in a concurrent
    # manner powered by Mojo::Promise and whatever your preferred event loop
    # is.

=head1 DESCRIPTION

In this class, an ITEM is:

    {
        name    => 'module/phase',     (unique per ITEM)
        queue   => 'update|build|etc', (only one of)
        job     => &coderef,
    }

For each item tracked, this class maintains a "promise" (as used and provided
by the Mojolicious framework, which itself borrowed them from modern
JavaScript).

IMPORTANT: There are two levels of promise things going on here.

=over

=item 1. Per-item promise (maintained by this class)

=item 2. Optional promises returned by the worker coderef

=back

If you're just waiting for your item to be done, use the per-item promise (see
L<PromiseChain::promiseFor>). The promise is created when the item is added and
does not change after (except to resolve or reject).

If your coderef finds that it has to block, it should return a Mojo::Promise
that will itself resolve to the result. Do this instead of blocking to keep up
maximum concurrency.

To control ordering of which updates are run and in what order, you would use a
promise chain to wait for its result, as done in makePromiseChain below.

=cut

=head1 METHODS

=head2 addItem

    my $code = sub { ... };
    $deps->addItem('job-name', 'queue-name', $code);

Adds an worker item (named as C<job-name>) to the item database. The worker
item is defined to run C<$code> to complete its task. $code should return its
result directly -- if it must block, it should instead return a
L<Mojo::Promise> that resolves to the proper result.

A L<Mojo::Promise> is created to await the result of running C<$code>. See
L<PromiseChain::promiseFor>.

Once an item is added with this method, dependencies can be added from the item
to other named worker items using L<PromiseChain::addDep>.

=cut

sub addItem {
    my ($self, $name, $queue, $code) = @_;
    my $p = Mojo::Promise->new;

    # $code may return a Promise or the result directly
    my $sub = sub { $p->resolve($code->()) };

    $self->items->{$name} = {
        name    => $name,
        queue   => $queue,
        job     => $sub,
        promise => $p,
    };

    # Add implicit dep here, though maybe it's better in calling code?
    my $lastItemInQueue = $self->last_queue_item->{$queue};
    $self->addDep($name, $lastItemInQueue)
        if $lastItemInQueue;
    $self->last_queue_item->{$queue} = $name;

    return $self;
}

=head2 addDep

    my @prerequisite_jobs = qw(other-job-name1 other-job-name2);

    # now the worker named 'job-name' should wait until after the results of both
    # other-job-name1 and other-job-name2 are ready
    $deps->addDep('job-name', @prerequisite_jobs);

Adds a dependency from a named worker item (as named when defined with
L<PromiseChain::addItem>) to a list of other named worker items.

This method merely updates internal bookkeeping, to do something with these
dependencies see L<PromiseChain::makePromiseChain>.

=cut

# Each entry in @deps is the NAME of an ITEM.
# $name is the NAME of an existing ITEM (see addItems)
sub addDep {
    my ($self, $name, @deps) = @_;
    my $depRef = $self->dependencies;
    $depRef->{$name} //= [];
    push @{$depRef->{$name}}, @deps;
    return $self;
}

=head2 depsFor

    my @dependency_item_names = $deps->depsFor('iten-name');

    # Use e.g. as
    my @item_promises = map { $deps->promiseFor($_) } @dependency_item_names;

=cut

sub depsFor {
    my ($self, $item) = @_;
    return @{$self->dependencies->{$item} // []};
}

=head2 promiseFor

    $jobPromise = $deps->promiseFor('item-name')->then(sub {
        say "Some other cute status update!";
    });

Returns the L<Mojo::Promise> that can be waited on for the given named work
item.

You can create promise chains manually based on these promises, even if you are
also using the all-in-one promise chain created from
L<PromiseChain::makePromiseChain>.

=cut

sub promiseFor {
    my ($self, $itemName) = @_;
    return $self->items->{$itemName}->{promise};
}

=head2 makePromiseChain

    # Items start building immediately
    my $result_promise = $deps->makePromiseChain;

    # Use your own start_promise, build waits until you're ready
    my $start_promise = Mojo::Promise->new;
    my $result_promise = $deps->makePromiseChain($start_promise);
    $start_promise->resolve;

This method is the real point to this whole class. Call it to return a promise
that waits for all work items (added using L<PromiseChain::addItem>), ensuring
that all items that have dependencies on other items (as specified using
L<PromiseChain::addDep>) are completed prior to commencing that item.

The returned promise will wait for all items to complete, including items that
have no dependencies listed at all.

There are two forms for this function. The first form returns the promise you
can wait on and immediately starts executing worker item jobs.

Use the second form if you wish to be able to control when the worker items
start executing: they all carry a dependency on the C<$start_promise> you
provide (potentially only an indirect dependency) and will not run until you
resolve the C<$start_promise>).

IMPORTANT: No checks are currently done to verify that the dependency graph you
build is actually a directed acyclic graph (DAG). If it is not you risk
deadlocks or other serious problems.

=cut

sub makePromiseChain {
    my $self = shift;
    my $start_promise = shift // Mojo::Promise->new->resolve;
    my @all_promises;

    foreach my $itemName (keys %{$self->items}) {
        my $item = $self->items->{$itemName}
            or die "No item $itemName";
        my $sub = $item->{job};
        my @deps =
            map { $_->{promise} }
            map { $self->items->{$_} or die "No dep item $itemName" }
            $self->depsFor($itemName);

        # What *has* to finish before we should start?
        my $base_promise =
            @deps
                ? Mojo::Promise->all(@deps)
                : $start_promise;

        # $sub will itself return a promise when called, which is needed
        # for this chain to work
        push @all_promises, $base_promise->then($sub);
    }

    my $all_promise = Mojo::Promise->all(@all_promises);
    return ($start_promise, $all_promise)
        if wantarray; # second calling form

    return $all_promise; # first calling form
}

1;

