package ksb::TaskManager 0.10;

use ksb;

=head1 SYNOPSIS

 assert_isa($app, 'ksb::Application');
 my $mgr = ksb::TaskManager->new($app);

 # build context must be setup first
 my $result = eval { $mgr->runAllTasks(); }

 # all module updates/builds/etc. complete

=head1 DESCRIPTION

This module consolidates the actual orchestration of all the module update,
buildsystem setup, configure, build, and install jobs once the
L<ksb::Application> has setup the L<ksb::BuildContext> for the current build.

In particular, the concurrent portion of the build is concentrated more-or-less
entirely within "runAllTasks", although other parts of the script have to be
aware of concurrency.

=cut

use ksb::Debug qw(:DEFAULT colorize);
use ksb::IPC::Pipe;
use ksb::IPC::Null;
use ksb::Util;

use Mojo::URL;

use IO::Select;
use POSIX qw(EINTR WNOHANG);

sub new ($class, $app)
{
    assert_isa($app, 'ksb::Application');

    my $opts = {
        ksb_app => $app,
    };

    return bless $opts, $class;
}

# returns shell-style result code
sub runAllTasks ($self)
{
    # What we're going to do is fork another child to perform the source
    # updates while we build.  Setup for this first by initializing some
    # shared memory.
    my $ctx = $self->{ksb_app}->context();
    my $result = 0;
    my $ipc;

    my $updateOptsSub = sub ($modName, $k, $v) {
        $ctx->setPersistentOption($modName, $k, $v);
    };

    $ipc = ksb::IPC::Pipe->new()
        if $ctx->getOption('async');

    $ipc //= ksb::IPC::Null->new();
    $ipc->setPersistentOptionHandler($updateOptsSub);

    if ($ipc->supportsConcurrency()) {
        $result = _handle_async_build ($ipc, $ctx);
        $ipc->outputPendingLoggedMessages()
            if debugging();
    } else {
        whisper ("Using no IPC mechanism\n");

        note ("\n b[<<<  Update Process  >>>]\n");
        $result = _handle_updates ($ipc, $ctx);

        note (" b[<<<  Build Process  >>>]\n");
        $result = _handle_build ($ipc, $ctx) || $result;
    }

    return $result;
}

# Internal API

# Function: _handle_updates
#
# Subroutine to update a list of modules.
#
# Parameters:
# 1. IPC module to pass results to.
# 2. Build Context, which will be used to determine the module update list.
#
# The ipc parameter contains an object that is responsible for communicating
# the status of building the modules.  This function must account for every
# module in $ctx's update phase to the ipc object before returning.
#
# Returns 0 on success, non-zero on error.
sub _handle_updates ($ipc, $ctx)
{
    my @update_list = $ctx->modulesInPhase('update');

    # No reason to print out the text if we're not doing anything.
    if (!@update_list) {
        $ipc->sendIPCMessage(ksb::IPC::ALL_UPDATING, "update-list-empty");
        $ipc->sendIPCMessage(ksb::IPC::ALL_DONE,     "update-list-empty");
        return 0;
    }

    if (not _check_for_ssh_agent($ctx)) {
        $ipc->sendIPCMessage(ksb::IPC::ALL_FAILURE, "ssh-failure");
        return 1;
    }

    my $kdesrc = $ctx->getSourceDir();
    if (not -e $kdesrc) {
        whisper ("KDE source download directory doesn't exist, creating.\n");

        if (not super_mkdir ($kdesrc)) {
            error ("Unable to make directory r[$kdesrc]!");
            $ipc->sendIPCMessage(ksb::IPC::ALL_FAILURE, "no-source-dir");

            return 1;
        }
    }

    # Once at this point, any errors we get should be limited to a module,
    # which means we can tell the build thread to start.
    $ipc->sendIPCMessage(ksb::IPC::ALL_UPDATING, "starting-updates");

    my $hadError = 0;
    foreach my $module (@update_list) {
        $ipc->setLoggedModule($module->name());

        # Note that this must be in this order to avoid accidentally not
        # running ->update() from short-circuiting if an error is noted.
        $hadError = !$module->update($ipc, $ctx) || $hadError;
    }

    $ipc->sendIPCMessage(ksb::IPC::ALL_DONE, "had_errors: $hadError");

    return $hadError;
}

# Builds the given module.
#
# Return value is the failure phase, or 0 on success.
sub _buildSingleModule ($ipc, $ctx, $module, $startTimeRef)
{
    $ctx->resetEnvironment();
    $module->setupEnvironment();

    # Cache module directories, e.g. to be consumed in kdesrc-run
    $module->setPersistentOption('build-dir', $module->fullpath('build'));
    $module->setPersistentOption('install-dir', $module->installationPath());

    my $fail_count = $module->getPersistentOption('failure-count') // 0;
    my ($resultStatus, $message) = $ipc->waitForModule($module);
    $ipc->forgetModule($module);

    if ($resultStatus eq 'failed') {
        error ("\tUnable to update r[$module], build canceled.");
        $module->setPersistentOption('failure-count', ++$fail_count);
        return 'update';
    } elsif ($resultStatus eq 'success') {
        note ("\tSource update complete for g[$module]: $message");
    }

    # Skip actually building a module if the user has selected to skip
    # builds when the source code was not actually updated. But, don't skip
    # if we didn't successfully build last time.
    elsif ($resultStatus eq 'skipped' &&
        !$module->getOption('build-when-unchanged') &&
        $fail_count == 0)
    {
        note ("\tSkipping g[$module], its source code has not changed.");
        return 0;
    } elsif ($resultStatus eq 'skipped') {
        note ("\tNo changes to g[$module] source, proceeding to build.");
    }

    # If the build gets interrupted, ensure the persistent options that are
    # written reflect that the build failed by preemptively setting the future
    # value to write. If the build succeeds we'll reset to 0 then.
    $module->setPersistentOption('failure-count', $fail_count + 1);

    $$startTimeRef = time;
    if ($module->build()) {
        $module->setPersistentOption('failure-count', 0);
        return 0;
    }

    return 'build'; # phase failed at
}

# Function: _handle_build
#
# Subroutine to handle the build process.
#
# Parameters:
# 1. IPC object to receive results from.
# 2. Build Context, which is used to determine list of modules to build.
#
# If the packages are not already checked-out and/or updated, this
# subroutine WILL NOT do so for you.
#
# This subroutine assumes that the source directory has already been set up.
# It will create the build directory if it doesn't already exist.
#
# If $builddir/$module/.refresh-me exists, the subroutine will
# completely rebuild the module (as if --refresh-build were passed for that
# module).
#
# Returns 0 for success, non-zero for failure.
sub _handle_build ($ipc, $ctx)
{
    my @modules = $ctx->modulesInPhase('build');

    # No reason to print building messages if we're not building.
    return 0
        unless @modules;

    # IPC queue should have a message saying whether or not to bother with the
    # build.
    $ipc->waitForStreamStart();

    $ctx->unsetPersistentOption('global', 'resume-list');

    my $outfile = pretending() ? '/dev/null'
                               : $ctx->getLogDir() . '/build-status';

    open (my $status_fh, '>', $outfile) or do {
        error (<<EOF);
 r[b[*] Unable to open output status file r[b[$outfile]
 r[b[*] You won't be able to use the g[--resume] switch next run.
EOF
        $outfile = undef;
    };

    my @build_done;
    my $result = 0;

    my $cur_module = 1;
    my $num_modules = scalar @modules;

    my $statusViewer = $ctx->statusViewer();
    $statusViewer->numberModulesTotal($num_modules);

    while (my $module = shift @modules) {
        my $moduleName = $module->name();
        my $moduleSet = $module->moduleSet()->name();
        my $modOutput = $moduleName;

        if (debugging(ksb::Debug::WHISPER)) {
            my $sysType = $module->buildSystemType();
            $modOutput .= " (build system $sysType)";
        }

        $moduleSet = " from g[$moduleSet]"
            if $moduleSet;
        note ("Building g[$modOutput]$moduleSet ($cur_module/$num_modules)");

        my $start_time = time;
        my $failedPhase = _buildSingleModule($ipc, $ctx, $module, \$start_time);
        my $elapsed = prettify_seconds(time - $start_time);

        if ($failedPhase) {
            # FAILURE
            $ctx->markModulePhaseFailed($failedPhase, $module);
            say $status_fh "$module: Failed on $failedPhase after $elapsed.";

            if ($result == 0) {
                # No failures yet, mark this as resume point
                my $moduleList = join(', ', map { "$_" } ($module, @modules));
                $ctx->setPersistentOption('global', 'resume-list', $moduleList);
            }

            $result = 1;

            if ($module->getOption('stop-on-failure')) {
                note ("\n$module didn't build, stopping here.");
                return 1; # Error
            }

            $statusViewer->numberModulesFailed(1 + $statusViewer->numberModulesFailed);
        } else {
            # Success
            say $status_fh "$module: Succeeded after $elapsed.";

            push @build_done, $moduleName; # Make it show up as a success

            $statusViewer->numberModulesSucceeded(1 + $statusViewer->numberModulesSucceeded);
        }

        $cur_module++;
        print "\n"; # Space things out
    }

    if ($outfile) {
        close $status_fh;

        # Update the symlink in latest to point to this file.
        my $logdir = $ctx->getSubdirPath('log-dir');
        my $statusFileLoc = "$logdir/latest/build-status";
        safe_unlink($statusFileLoc)
            if -l $statusFileLoc;
        symlink($outfile, $statusFileLoc);
    }

    info ("<<<  g[PACKAGES SUCCESSFULLY BUILT]  >>>")
        if scalar @build_done > 0;

    my $successes = scalar @build_done;
    my $mods = $successes == 1 ? 'module' : 'modules';

    if (not pretending()) {
        # Print out results, and output to a file
        my $kdesrc = $ctx->getSourceDir();

        open (my $built, '>', "$kdesrc/successfully-built");
        foreach my $module (@build_done) {
            info ("$module")
                if $successes <= 10;
            say $built "$module";
        }
        close $built;

        info ("Built g[$successes] $mods") if $successes > 10;
    } else {
        # Just print out the results
        if ($successes <= 10) {
            info ('g[', join ("]\ng[", @build_done), ']');
        } else {
            info ("Built g[$successes] $mods")
                if $successes > 10;
        }
    }

    info (' '); # Space out nicely

    return $result;
}

# Function: _handle_async_build
#
# This subroutine special-cases the handling of the update and build phases, by
# performing them concurrently (where possible), using forked processes.
#
# Only one thread or process of execution will return from this procedure. Any
# other processes will be forced to exit after running their assigned module
# phase(s).
#
# We also redirect ksb::Debug output messages to be sent to a single process
# for display on the terminal instead of allowing them all to interrupt each
# other.
#
# Parameters:
# 1. IPC Object to use for sending/receiving update/build status. It must be
# an object type that supports IPC concurrency (e.g. IPC::Pipe).
# 2. Build Context to use, from which the module lists will be determined.
#
# Returns 0 on success, non-zero on failure.
sub _handle_async_build ($ipc, $ctx)
{
    # The exact method for async is that two children are forked.  One child
    # is a source update process.  The other child is a monitor process which will
    # hold status updates from the update process so that the updates may
    # happen without waiting for us to be ready to read.

    print "\n"; # Space out from metadata messages.

    my $result = 0;
    my $monitorPid = fork;
    if ($monitorPid == 0) {
        # child
        my $updaterToMonitorIPC = ksb::IPC::Pipe->new();
        my $updaterPid = fork;

        $SIG{INT} = sub { POSIX::_exit(EINTR); };

        if ($updaterPid) {
            $0 = 'kdesrc-build-updater';
            $updaterToMonitorIPC->setSender();
            ksb::Debug::setIPC($updaterToMonitorIPC);

            POSIX::_exit (_handle_updates ($updaterToMonitorIPC, $ctx));
        } else {
            $0 = 'kdesrc-build-monitor';
            $ipc->setSender();
            $updaterToMonitorIPC->setReceiver();

            $ipc->setLoggedModule('#monitor#'); # This /should/ never be used...
            ksb::Debug::setIPC($ipc);

            POSIX::_exit (_handle_monitoring ($ipc, $updaterToMonitorIPC));
        }
    } else {
        # Still the parent, let's do the build.
        $ipc->setReceiver();
        $result = _handle_build ($ipc, $ctx);
    }

    $ipc->waitForEnd();
    $ipc->close();

    # Display a message for updated modules not listed because they were not
    # built.
    my $unseenModulesRef = $ipc->unacknowledgedModules();
    if (%$unseenModulesRef) {
        note ("The following modules were updated but not built:");
        foreach my $modulename (keys %$unseenModulesRef) {
            note ("\t$modulename");
        }
    }

    # It's possible if build fails on first module that git or svn is still
    # running. Make them stop too.
    if (waitpid ($monitorPid, WNOHANG) == 0) {
        kill 'INT', $monitorPid;

        # Exit code is in $?.
        waitpid ($monitorPid, 0);
        $result = 1 if $? != 0;
    }

    return $result;
}

# Function: _check_for_ssh_agent
#
# Checks if we are supposed to use ssh agent by examining the environment, and
# if so checks if ssh-agent has a list of identities.  If it doesn't, we run
# ssh-add (with no arguments) and inform the user.  This can be controlled with
# the disable-agent-check parameter.
#
# Parameters:
# 1. Build context
sub _check_for_ssh_agent ($ctx)
{
    # Don't bother with all this if the user isn't even using SSH.
    return 1 if pretending();
    return 1 if $ctx->getOption('disable-agent-check');

    my @gitServers = grep {
        $_->scmType() eq 'git'
    } ($ctx->modulesInPhase('update'));

    my @sshServers, grep {
        # Check for git+ssh:// or git@git.kde.org:/path/etc.
        my $url = Mojo::URL->new($_->getOption('repository'));
        ($url->scheme eq 'git+ssh') || (($url->userinfo // '') eq 'git' && $url->host eq 'git.kde.org');
    } @gitServers;

    return 1 unless @sshServers;
    whisper ("\tChecking for SSH Agent");

    # We're using ssh to download, see if ssh-agent is running.
    return 1 unless exists $ENV{'SSH_AGENT_PID'};

    my $pid = $ENV{'SSH_AGENT_PID'};

    # It's supposed to be running, let's see if there exists the program with
    # that pid (this check is linux-specific at the moment).
    if (-d "/proc" and not -e "/proc/$pid") {
        local $" = ', '; # override list interpolation separator

        warning (<<DONE);
y[b[ *] SSH Agent is enabled, but y[doesn't seem to be running].
y[b[ *] The agent is needed for these modules:
y[b[ *]   b[@sshServers]
y[b[ *] Please check that the agent is running and its environment variables defined
DONE
        return 0;
    }

    # The agent is running, but does it have any keys?  We can't be more specific
    # with this check because we don't know what key is required.
    my $noKeys = 0;

    filter_program_output(sub { $noKeys ||= /no identities/ }, 'ssh-add', '-l');

    return 1
        unless $noKeys;

    say colorize (<<EOF);
b[y[*] SSH Agent does not appear to be managing any keys.  This will lead to you
being prompted for every module update for your SSH passphrase.  So, we're
running g[ssh-add] for you.  Please type your passphrase at the prompt when
requested, (or simply Ctrl-C to abort the script).
EOF
    my @commandLine = ('ssh-add');
    my $identFile = $ctx->getOption('ssh-identity-file');
    push (@commandLine, $identFile)
        if $identFile;

    my $result = system (@commandLine);

    # Run this code for both death-by-signal and nonzero return
    if ($result) {
        my $rcfile = $ctx->rcFile();

        say colorize(<<EOF);

y[b[*] Unable to add SSH identity, aborting.
y[b[*] If you don't want kdesrc-build to check in the future,
y[b[*] Set the g[disable-agent-check] option to g[true] in your $rcfile.

EOF

        return 0;
    }

    return 1;
}

# Function: _handle_monitoring
#
# This is the main subroutine for the monitoring process when using IPC::Pipe.
# It reads in all status reports from the source update process and then holds
# on to them.  When the build process is ready to read information we send what
# we have.  Otherwise we're waiting on the update process to send us something.
#
# This convoluted arrangement is required to allow the source update
# process to go from start to finish without undue interruption on it waiting
# to write out its status to the build process (which is usually busy).
#
# Parameters:
# 1. the IPC object to use to send to build process.
# 2. the IPC object to use to receive from update process.
#
# Returns 0 on success, non-zero on failure.
sub _handle_monitoring ($ipcToBuild, $ipcFromUpdater)
{
    my @msgs;  # Message queue.

    # We will write to the build process and read from the update process.

    my $sendFH = $ipcToBuild->{fh}     || croak_runtime('??? missing pipe to build proc');
    my $recvFH = $ipcFromUpdater->{fh} || croak_runtime('??? missing pipe from monitor');

    my $readSelector  = IO::Select->new($recvFH);
    my $writeSelector = IO::Select->new($sendFH);

    # Start the loop.  We will be waiting on either read or write ends.
    # Whenever select() returns we must check both sets.
    while (
        my ($readReadyRef, $writeReadyRef) =
            IO::Select->select($readSelector, $writeSelector, undef))
    {
        if (!$readReadyRef && !$writeReadyRef) {
            # Some kind of error occurred.
            return 1;
        }

        # Check for source updates first.
        if (@{$readReadyRef}) {
            undef $@;
            my $msg = eval { $ipcFromUpdater->receiveMessage(); };

            # undef msg indicates EOF, so check for exception obj specifically
            die $@ if $@;

            # undef can be returned on EOF as well as error.  EOF means the
            # other side is presumably done.
            if (! defined $msg) {
                $readSelector->remove($recvFH);
                last; # Select no longer needed, just output to build.
            } else {
                push @msgs, $msg;

                # We may not have been waiting for write handle to be ready if
                # we were blocking on an update from updater thread.
                $writeSelector->add($sendFH)
                    unless $writeSelector->exists($sendFH);
            }
        }

        # Now check for build updates.
        if (@{$writeReadyRef}) {
            # If we're here the update is still going.  If we have no messages
            # to send wait for that first.
            if (not @msgs) {
                $writeSelector->remove($sendFH);
            } else {
                # Send the message (if we got one).
                if (!$ipcToBuild->sendMessage(shift @msgs)) {
                    error ("r[mon]: Build process stopped too soon! r[$!]");
                    return 1;
                }
            }
        }
    }

    # Send all remaining messages.
    for my $msg (@msgs) {
        if (!$ipcToBuild->sendMessage($msg)) {
            error ("r[mon]: Build process stopped too soon! r[$!]");
            return 1;
        }
    }

    $ipcToBuild->close();

    return 0;
}

1;
