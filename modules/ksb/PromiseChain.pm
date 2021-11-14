#!/usr/bin/env perl

package ksb::PromiseChain 0.10;

use Mojo::Base -base;
use Mojo::Promise;

has 'items'        => sub { return {} }; # nodes
has 'dependencies' => sub { return {} }; # edges
has 'orderings'    => sub { return {} }; # semi-edges for queuing

# Maps each queue to the last item entered in that queue for dependencies
# This imparts an implicit ordering. Maybe better to do it explicitly?
has 'last_queue_item' => sub { return {} };

# If set to true, the promise chain that is built will be configured so that
# all new jobs are rejected once one job fails.
has 'abort_after_failure' => 0;

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

    # Uncomment for --stop-on-failure semantics
    # $deps->abort_after_failure(1);

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

The worker item provided is run within a work queue named by C<queue-name>,
which needs no further setup besides naming the queue. Each queue will only
ever run one item at a time.

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
    $self->addOrdering($name, $lastItemInQueue)
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

=head2 addOrdering

    # now the worker named 'job-name' will wait until 'other-job-name' has
    # finished (whatever its result) before proceeding.
    $deps->addOrdering('job-name', 'other-job-name');

Adds an ordering (not a dependency!) from a named worker item (as named when
defined with L<PromiseChain::addItem>) to a single other named worker item.

This simply means that the listed job is forced to wait for the other job to
finish, but any errors in the other job are ignored. Used for the queuing
feature.

This method merely updates internal bookkeeping, to do something with these
orderings see L<PromiseChain::makePromiseChain>.

=cut

# Each entry in @deps is the NAME of an ITEM.
# $name is the NAME of an existing ITEM (see addItems)
sub addOrdering {
    my ($self, $name, $beforeItemName) = @_;
    $self->orderings->{$name} = $beforeItemName;
    return $self;
}

=head2 depsFor

    my @dependency_item_names = $deps->depsFor('item-name');

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

    my $eat_errors = sub { "Masked an ordering-only module failure" };

    # Handle --stop-on-failure by setting up a promise that we can reject when
    # it's time to cancel remaining jobs waiting on a promise to fulfill to
    # start
    my $do_abort;

    $do_abort = Mojo::Promise->new
        if $self->abort_after_failure; # leave undef if we should keep going

    foreach my $itemName (keys %{$self->items}) {
        my $item = $self->items->{$itemName}
            or die "No item $itemName";
        my $sub = $item->{job};
        my @deps =
            map { $self->items->{$_}->{promise} or die "No dep item $_" }
            $self->depsFor($itemName);

        # Add error-eating catch statements for order-only dependencies so that
        # the promises not affected by rejection can still continue
        if (my $priorItemName = $self->orderings->{$itemName} // '') {
            my $priorItem = $self->items->{$priorItemName}
                or die "No ordering item $priorItemName";

            my $priorItemPromise = $priorItem->{promise};
            if ($do_abort) {
                # The "race" below will abort us early if needed
                push @deps, $priorItemPromise;
            } else {
                push @deps, $priorItemPromise->catch($eat_errors);
            }
        }

        # What *has* to finish before we should start?
        my $base_promise =
            @deps
                ? @deps == 1 ? $deps[0] : Mojo::Promise->all(@deps)
                : $start_promise;

        # The race ensures that every job waiting on do_abort will fail early
        # once do_abort rejects, as we set it to do later.
        $base_promise = Mojo::Promise->race($base_promise, $do_abort)
            if $do_abort;

        # $sub will itself return a promise when called, which is needed
        # for this chain to work
        push @all_promises, $base_promise->then($sub)->catch(sub {
            # err handler, return a value to keep the Promise->all below from
            # failing fast.
            if ($do_abort) {
                # Stop the build once event loop resumes
                $do_abort->reject("A build step failed and stop-on-failure is enabled")
            } else {
                # The build will continue, but not for dependent promises
                $item->{promise}->reject("Prerequisite to $itemName failed");
            }

            # We've handled the error, let the rest of the build proceed if it
            # otherwise would.
            return 0; # Failure result
        });
    }

    die "No promises to chain based on provided orderings!"
        unless @all_promises;

    my $p = Mojo::Promise->all(@all_promises);
    $p = $p->then(sub { $do_abort->resolve })
        if $do_abort; # Avoids a warning about unused promises
    return $p;
}

1;

