<!--
SPDX-FileCopyrightText: 2022 Michael Pyne <mpyne@kde.org>
SPDX-License-Identifier: CC-BY-4.0
-->

# IPC Notes

To support the [async](https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html#conf-async)
parameter, which permits network updates to be run in parallel with the build process, kdesrc-build implements
some limited inter-process communication (IPC).

In reality there are 3 separate long-term processes during an async build:

                 +-----------------+     +---------------+        +------------+
                 |                 |     |               |        |            |
                 |  main / build   <------    monitor    <---------    update  |
                 |                 |  ^  |               |   ^    |            |
                 +--------^--------+  |  +---------------+   |    +------------+
                          |           |                      |
                          |         $ipc            $updaterToMonitorIPC
                          |
                          |
                 +--------v--------+
                 |                 |
    user ------->|       TTY       |
                 |                 |
                 +-----------------+

- 1. The main (build) process
- 2. The update process, normally squelched
- 3. A "monitor" process, connected to the other two

## Why IPC is necessary

IPC is used to carry information about the status of build updates back to the main process.

Over the years this has evolved to include, using a custom app-specific protocol:

- 1. Success/failure codes (per-module)
- 2. Whether the module was even attempted to be updated at all
- 3. Failure codes (overall)
- 4. Log messages for a module (normally squelched during update)
- 5. Changes to persistent options (must be forwarded to main proc to be persisted)
- 6. "Post build" messages, which must be shown by the main thread just before exit.

You could in principle do most of this by doing something like serializing
changes into a file after each module update and then reading the results from
the file in the main thread using file locking or similar. However it seemed
simpler to ferry the information over IPC pipes instead.

## How it works, today

At this stage, the IPC data flow is mediated by [ksb::IPC](https://metacpan.org/pod/ksb%3A%3AIPC), which is an
interface class with a couple of methods meant to be reimplemented by
subclasses, and which implements the IPC API on top of those subclass-defined
methods.

The user code in kdesrc-build is required to create the IPC object before
forking using ["fork" in perlfunc](https://metacpan.org/pod/perlfunc#fork). The parent then declares that it will be the
receiver and the child declared that it will be the sender.

### Monitor process

Early experiments used only the two build (main) and update processes. However
this quickly ran into issues trying to keep the main process U/I in sync.
During a build there was no easy way to monitor the build child's output along
with the update child's, and the update child would block if it tried to write
too much output to the build process if the build process was itself blocked
waiting for a build.

The solution was to reinvent a message queue, poorly, for much the same reason
you would use a message queue today in a distributed architecture. It
simplified the problem for build and update and allowed the update process to
send at will without blocking, and likewise the build thread did not have to
worry about blocking by trying to read from the child unless it was safe to
wait.

The monitor simply uses a second [ksb::IPC](https://metacpan.org/pod/ksb%3A%3AIPC) object to connect to the update
child process, and feeds messages it receives from the child to the parent, in
the order received and exactly once.

### Ordering the update and build

To keep the build from proceeding before the update has completed, the IPC
class supports methods to wait for the module to complete if it hasn't already.
By their nature these are blocking methods, ultimately these block waiting on
I/O from the monitor.

This means that the build process will block forever if the update thread
forgets to send the right message. The update process should build modules in
the same order the build process will expect them, though this won't cause the
build to block forever if it does not.

### Squelching log messages

The various logging methods all output the message immediately. This is
problematic in the context of concurrent build and update processes, especially
since most log messages do not duplicate the name of the module (since it's
normally nearby in the U/I output).

We resolve this tension by having the update process pass the IPC object into
ksb::Debug, which will then feed the output to the IPC handle instead of
STDOUT/STDERR. In the build process, as log messages are read in from the
update process, they are stored and then printed out once it comes time to
build the module.

This system only works because the update and build processes are separate
processes.  The 'modern' scheme I'm building towards does not require the
existence of a separate update process at all, but we may still retain it to
make squelching work.

### Commands that do not require IPC

The log\_command() call in [ksb::Util](https://metacpan.org/pod/ksb%3A%3AUtil) also uses a fork-based construct to read
I/O from a child (to redirect output to the log file and/or to a callback).

It is safe to use this function from the update thread, as long as we are
disciplined about using unique names for each log-file. The update process will
set the `latest` and `error.log` symlinks as necessary, and the main process
will find `error.log` where it expects to when making the report at the end.

Note that this works only if the base log directory for the module is created
in [ksb::BuildContext](https://metacpan.org/pod/ksb%3A%3ABuildContext) before the fork occurs!

## How it will work, tomorrow

Looking back, the IPC stuff I coded isn't as bad as I remember it to be. However
there are still good reasons to work to replace it with some of the superior options
supported by [Mojolicious](https://docs.mojolicious.org/).

- Easier use of the Web and APIs

    A lot of this work was kicked off based on conversations at Akademy 2018, where
    people asked about a way to track the progress of a kdesrc-build build using
    APIs or RPC.  kdesrc-build isn't setup today to host a web server interface
    **during** the build, and the [ksb::IPC](https://metacpan.org/pod/ksb%3A%3AIPC) stuff isn't helping on that front.

    But this is what Mojolicious is built for.

    However not only would it be good to have kdesrc-build be able to feed
    information to e.g. a running Plasma applet, but it would also be good for
    kdesrc-build to be able to make API calls to KDE infrastructure, for things
    like bug management, creating new work branches in Gitlab, and so on.

    For all these things it will be greatly helpful to have the Web-native
    capability and event loop provided by Mojolicious.

- Improved API

    In addition, Mojolicious's concurrent code is just a simpler API. It doesn't
    hurt that their "promise"-based API is the same API you'd find in JavaScript,
    including browsers and Node.js ecosystems.

    Unfortunately a lot of this is a fair bit different than what kdesrc-build has
    been built to date.  But I think I understand how to port it over time without
    breaking everything.

- Improved code correctness

    Even though we ferry a lot of information from the update process to the main
    process, there are still information types we do not that might be considered
    bugs. For example, [ksb::OptionsBase](https://metacpan.org/pod/ksb%3A%3AOptionsBase)'s `getOption`/`setOption` methods
    (which power the same in [ksb::Module](https://metacpan.org/pod/ksb%3A%3AModule) and [ksb::BuildContext](https://metacpan.org/pod/ksb%3A%3ABuildContext) do not make
    any attempt to forward changes to the options dictionaries in the update
    process back to the main process.

    Mojolicious's "subprocess" feature would allow us to move the blocking portions
    of the update command into a subprocess, while allowing the business logic to
    be retained in the main process.  This way there is only one place to call
    `getOption`/`setOption` from, simplifying how the information flows.

- Fewer bugs

    Mojolicious has quite a few more users testing their code base compared to my
    custom IPC stuff.

- Finer granularity

    Ultimately, Mojolicious would permit the main process to split the work of the
    build process up to an even finer degree than "module update" or "module
    build".  This will allow the operating system a better opportunity to let
    kdesrc-build use whatever is available between disk I/O, CPU, or network I/O.

### The plan

Ultimately, the plan is to introduce some porting-aid functions to [ksb::Util](https://metacpan.org/pod/ksb%3A%3AUtil)
and use these to slowly port calls to `log_command()` to split the function into
two parts:

- 1. Generate a promise-based logging command
- 2. Wait on the promise for the result

By splitting the work into two steps we can avoid changing too much at once,
while allowing for the slow merger of promise-based code into a chain of
promises that can be handled at once using standard [Mojo::Promise](https://metacpan.org/pod/Mojo%3A%3APromise) methods.

The significant limitation to this is that we **cannot call `promise->wait`**
recursively!

#### The recursive promise->wait issue

The issue is that `promise->wait` requires that the I/O loop **not** be
running, for much the same reason that we avoid nested event loops with
Qt-based GUI programs.  `wait` is simply a convenience method to run the event
loop just long enough for the given promise to resolve or reject.

If multiple promises are trying to `wait` at the same time in the presence of truly
concurrent code then nothing good can happen.

It might be possible to do this safely with structured concurrency (i.e. if the
second promise being awaited were _guaranteed_ to always complete before the
first promise then it should not be an issue). There might be a way to create a
new [Mojo::IOLoop](https://metacpan.org/pod/Mojo%3A%3AIOLoop) to use with the inner promise so that we can safely wait on
it.

But it's better to avoid it entirely.  That's why the porting methods I've written
check to see if the I/O loop is running and, if it is, aborts the program.

#### Implication of recursive waiting problems

Since we can't wait recursively on promises, we generally need to port from
blocking code to promises from leaf function calls on up.

As an example if a call tree looks like:

    + runAllTasks
    \-+ handle_update
      \-+ ksb::Module::update
        \-+ ksb::Updater::Git::updateInternal
          \-+ ksb::Updater::Git::updateExistingClone
            +-+ ksb::Updater::Git::_auxFunction1
            | \-- ksb::Updater::Git::_nestedAuxFunction1
            \---- ksb::Updater::Git::_nestedAuxFunction2

We might first port the "nested aux functions", making them create promises and
then immediately await them so that they remain blocking.

However, once we port their caller `_auxFunction1`, and make `_auxFunction1`
create a promise and then await it to remain blocking, we **must** get rid of
the blocking calls within the "nested aux functions", and have them deal only
in promises.

This will apply so on up the chain. At each level of the call tree that we want
to block on a promise for each of porting, **all child calls** must be
promise-native with no blocking at all!

This can require rewriting complicated functions that have several
"await\_result" calls to instead return a chain of promises.
