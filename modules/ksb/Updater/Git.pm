package ksb::Updater::Git 0.15;

# Module which is responsible for updating git-based source code modules. Can
# have some features overridden by subclassing (see ksb::Updater::KDEProject
# for an example).

use ksb;

use parent qw(ksb::Updater);

use ksb::BuildException;
use ksb::Debug;
use ksb::IPC::Null;
use ksb::Util;

use Mojo::File;

use File::Basename; # basename
use File::Spec;     # tmpdir
use POSIX qw(strftime);
use List::Util qw(first);
use IPC::Cmd qw(run_forked);

use constant {
    DEFAULT_GIT_REMOTE => 'origin',
};

# scm-specific update procedure.
# May change the current directory as necessary.
sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $ipc  = shift;

    $self->{ipc} = $ipc // ksb::IPC::Null->new();
    return $self->updateCheckout();
    delete $self->{ipc};
}

sub name
{
    return 'git';
}

sub currentRevisionInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    return $self->commit_id('HEAD');
}

# Returns the current sha1 of the given git "commit-ish".
sub commit_id
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $commit = shift or croak_internal("Must specify git-commit to retrieve id for");
    my $module = $self->module();

    my $gitdir = $module->fullpath('source') . '/.git';

    # Note that the --git-dir must come before the git command itself.
    my ($id, undef) = filter_program_output(
        undef, # No filter
        qw/git --git-dir/, $gitdir, 'rev-parse', $commit,
    );
    chomp $id if $id;

    return $id;
}

sub _verifyRefPresent
{
    my ($self, $module, $repo) = @_;
    my ($ref, $commitType) = $self->_determinePreferredCheckoutSource($module);

    return 1 if pretending();

    $ref = 'HEAD' if $commitType eq 'none';

    my $hashref = run_forked("git ls-remote --exit-code $repo $ref",
        { timeout => 10, discard_output => 1, terminate_on_parent_sudden_death => 1});
    my $result = $hashref->{exit_code};

    return 0 if ($result == 2); # Connection successful, but ref not found
    return 1 if ($result == 0); # Ref is present

    croak_runtime("git had error exit $result when verifying $ref present in repository at $repo");
}

# Perform a git clone to checkout the latest branch of a given git module
#
# First parameter is the repository (typically URL) to use.
# Throws an exception if it fails.
sub _clone
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $git_repo = shift;
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my @args = ('--', $git_repo, $srcdir);

    my $ipc = $self->{ipc} // croak_internal ('Missing IPC object');

    note ("Cloning g[$module]");

    p_chdir($module->getSourceDir());

    my ($commitId, $commitType) = $self->_determinePreferredCheckoutSource($module);

    if ($commitType ne 'none') {
        $commitId =~ s,^refs/tags/,,;   # git-clone -b doesn't like refs/tags/
        unshift @args, '-b', $commitId; # Checkout branch right away
    }

    if (0 != log_command($module, 'git-clone', ['git', 'clone', '--recursive', @args])) {
        croak_runtime("Failed to make initial clone of $module");
    }

    $ipc->notifyPersistentOptionChange(
        $module->name(), 'git-cloned-repository', $git_repo);

    p_chdir($srcdir);

    # Setup user configuration
    if (my $name = $module->getOption('git-user')) {
        my ($username, $email) = ($name =~ /^([^<]+) +<([^>]+)>$/);
        if (!$username || !$email) {
            croak_runtime("Invalid username or email for git-user option: $name".
                " (should be in format 'User Name <username\@example.net>'");
        }

        whisper ("\tAdding git identity $name for new git module $module");
        my $result = (safe_system(qw(git config --local user.name), $username)
                        >> 8) == 0;

        $result = (safe_system(qw(git config --local user.email), $email)
                        >> 8 == 0) || $result;

        if (!$result) {
            warning ("Unable to set user.name and user.email git config for y[b[$module]!");
        }
    }

    return;
}

# Checks that the required source dir is either not already present or is empty.
# Throws an exception if that's not true.
sub _verifySafeToCloneIntoSourceDir
{
    my ($module, $srcdir) = @_;

    if (-e "$srcdir" && !is_dir_empty($srcdir)) {
        if ($module->getOption('#delete-my-patches')) {
            warning ("\tRemoving conflicting source directory " .
                     "as allowed by --delete-my-patches");
            warning ("\tRemoving b[$srcdir]");
            safe_rmtree($srcdir) or
                croak_internal("Unable to delete $srcdir!");
        }
        else {
            error (<<EOF);
The source directory for b[$module] does not exist. kdesrc-build would download
it, except there is already a file or directory present in the desired source
directory:
\ty[b[$srcdir]

Please either remove the source directory yourself and re-run this script, or
pass the b[--delete-my-patches] option to kdesrc-build and kdesrc-build will
try to do so for you.

DO NOT FORGET TO VERIFY THERE ARE NO UNCOMMITTED CHANGES OR OTHER VALUABLE
FILES IN THE DIRECTORY.

EOF

            if (-e "$srcdir/.svn") {
                error ("svn status of $srcdir:");
                system('svn', 'st', '--non-interactive', $srcdir);
            }

            croak_runtime('Conflicting source-dir present');
        }
    }

    return;
}

# Either performs the initial checkout or updates the current git checkout
# for git-using modules, as appropriate.
#
# If errors are encountered, an exception is raised.
#
# Returns the number of *commits* affected.
sub updateCheckout
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');

    if (-d "$srcdir/.git") {
        # Note that this function will throw an exception on failure.
        return $self->updateExistingClone();
    }
    else {
        _verifySafeToCloneIntoSourceDir($module, $srcdir);

        my $git_repo = $module->getOption('repository');

        if (!$git_repo) {
            croak_internal("Unable to checkout $module, you must specify a repository to use.");
        }

        if (!$self->_verifyRefPresent($module, $git_repo)) {
            croak_runtime(
                $self->_moduleIsNeeded()
                    ? "$module build was requested, but it has no source code at the requested git branch"
                    : "The required git branch does not exist at the source repository"
            );
        }

        $self->_clone($git_repo);

        return 1 if pretending();
        return count_command_output('git', '--git-dir', "$srcdir/.git", 'ls-files');
    }

    return 0;
}

# Intended to be reimplemented
sub _moduleIsNeeded
{
    return 1;
}

#
# Determine whether or not _setupRemote should manage the configuration of the git push URL for the repo.
#
# Return value: boolean indicating whether or not _setupRemote should assume control over the push URL.
#
sub isPushUrlManaged
{
    return 0;
}

#
# Ensures the given remote is pre-configured for the module's git repository.
# The remote is either set up from scratch or its URLs are updated.
#
# Param $remote name (alias) of the remote to configure
#
# Throws an exception on error.
#
sub _setupRemote
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $remote = shift;

    my $module = $self->module();
    my $repo = $module->getOption('repository');
    my $hasOldRemote = $self->hasRemote($remote);

    if ($hasOldRemote) {
        whisper("\tUpdating the URL for git remote $remote of $module ($repo)");
        if (log_command($module, 'git-fix-remote', ['git', 'remote', 'set-url', $remote, $repo]) != 0) {
            croak_runtime("Unable to update the URL for git remote $remote of $module ($repo)");
        }
    }
    elsif (log_command($module, 'git-add-remote', ['git', 'remote', 'add', $remote, $repo]) != 0) {
        whisper("\tAdding new git remote $remote of $module ($repo)");
        croak_runtime("Unable to add new git remote $remote of $module ($repo)");
    }

    if ($self->isPushUrlManaged()) {
        #
        # pushInsteadOf does not work nicely with git remote set-url --push
        # The result would be that the pushInsteadOf kde: prefix gets ignored.
        #
        # The next best thing is to remove any preconfigured pushurl and restore the kde: prefix mapping that way.
        # This is effectively the same as updating the push URL directly because of the remote set-url executed
        # previously by this function for the fetch URL.
        #
        chomp (my $existingPushUrl = qx"git config --get remote.$remote.pushurl");
        if ($existingPushUrl) {
            info("\tRemoving preconfigured push URL for git remote $remote of $module: $existingPushUrl");

            if (log_command($module, 'git-fix-remote', ['git', 'config', '--unset', "remote.$remote.pushurl"]) != 0) {
                croak_runtime("Unable to remove preconfigured push URL for git remote $remote of $module: $existingPushUrl");
            }
        }
    }
}

# Selects a git remote for the user's selected repository (preferring a
# defined remote if available, using 'origin' otherwise).
#
# Assumes the current directory is already set to the source directory.
#
# Throws an exception on error.
#
# Return value: Remote name that should be used for further updates.
#
# See also the 'repository' module option.
sub _setupBestRemote
{
    my $self     = assert_isa(shift, 'ksb::Updater::Git');
    my $module   = $self->module();
    my $cur_repo = $module->getOption('repository');
    my $ipc      = $self->{ipc} // croak_internal ('Missing IPC object');

    # Search for an existing remote name first. If none, add our alias.
    my @remoteNames = $self->bestRemoteName();
    my $chosenRemote = @remoteNames ? $remoteNames[0] : DEFAULT_GIT_REMOTE;

    $self->_setupRemote($chosenRemote);

    # Make a notice if the repository we're using has moved.
    my $old_repo = $module->getPersistentOption('git-cloned-repository');
    if ($old_repo and ($cur_repo ne $old_repo)) {
        note (" y[b[*]\ty[$module]'s selected repository has changed");
        note (" y[b[*]\tfrom y[$old_repo]");
        note (" y[b[*]\tto   b[$cur_repo]");
        note (" y[b[*]\tThe git remote named b[", DEFAULT_GIT_REMOTE, "] has been updated");

        # Update what we think is the current repository on-disk.
        $ipc->notifyPersistentOptionChange(
            $module->name(), 'git-cloned-repository', $cur_repo);
    }

    return $chosenRemote;
}

# Completes the steps needed to update a git checkout to be checked-out to
# a given remote-tracking branch. Any existing local branch with the given
# branch set as upstream will be used if one exists, otherwise one will be
# created. The given branch will be rebased into the local branch.
#
# No checkout is done, this should be performed first.
# Assumes we're already in the needed source dir.
# Assumes we're in a clean working directory (use git-stash to achieve
#   if necessary).
#
# First parameter is the remote to use.
# Second parameter is the branch to update to.
# Returns boolean success flag.
# Exception may be thrown if unable to create a local branch.
sub _updateToRemoteHead
{
    my $self = shift;
    my ($remoteName, $branch) = @_;
    my $module = $self->module();

    # The 'branch' option requests a given head in the user's selected
    # repository. Normally the remote head is mapped to a local branch,
    # which can have a different name. So, first we make sure the remote
    # head is actually available, and if it is we compare its SHA1 with
    # local branches to find a matching SHA1. Any local branches that are
    # found must also be remote-tracking. If this is all true we just
    # re-use that branch, otherwise we create our own remote-tracking
    # branch.
    my $branchName = $self->getRemoteBranchName($remoteName, $branch);

    # Check if this branchName we want was already the branch we were on. If
    # not, and if we stashed local changes, then we might dump a bunch of
    # conflicts in the repo if we un-stash those changes after a branch switch.
    # See issue #67.
    my ($existingBranch, undef) = filter_program_output(undef, qw(git branch --show-current));
    chomp $existingBranch if defined ($existingBranch);

    # The result is empty if in 'detached HEAD' state where we should also
    # clearly not switch branches if there are local changes.
    if ($module->getOption('#git-was-stashed') &&
        (!$existingBranch || ($existingBranch ne $branchName)))
    {
        # Make error message make more sense
        $existingBranch ||= 'Detached HEAD';
        $branchName     ||= "New branch to point to $remoteName/$branch";

        info (<<EOF);
 y[b[*] The module y[b[$module] had local changes from a different branch than expected:
 y[b[*]   Expected branch: b[$branchName]
 y[b[*]   Actual branch:   b[$existingBranch]
 y[b[*]
 y[b[*] To avoid conflict with your local changes, b[$module] will not be updated, and the
 y[b[*] branch will remain unchanged, so it may be out of date from upstream.
EOF

        $self->_notifyPostBuildMessage(
            " y[b[*] b[$module] was not updated as it had local changes against an unexpected branch.");
        return 1;
    }

    if (!$branchName) {
        my $newName = $self->makeBranchname($remoteName, $branch);
        whisper ("\tUpdating g[$module] with new remote-tracking branch y[$newName]");
        if (0 != log_command($module, 'git-checkout-branch',
                      ['git', 'checkout', '-b', $newName, "$remoteName/$branch"]))
        {
            croak_runtime("Unable to perform a git checkout of $remoteName/$branch to a local branch of $newName");
        }
    }
    else {
        whisper ("\tUpdating g[$module] using existing branch g[$branchName]");
        if (0 != log_command($module, 'git-checkout-update',
                      ['git', 'checkout', $branchName]))
        {
            croak_runtime("Unable to perform a git checkout to existing branch $branchName");
        }

        #
        # Given that we're starting with a 'clean' checkout, it's now simply a fast-forward
        # to the remote HEAD (previously we pulled, incurring additional network I/O).
        #
        return 0 == log_command($module, 'git-rebase',
                      ['git', 'reset', '--hard', "$remoteName/$branch"]);
    }

    return 1;
}

# Completes the steps needed to update a git checkout to be checked-out to
# a given commit. The local checkout is left in a detached HEAD state,
# even if there is a local branch which happens to be pointed to the
# desired commit. Based the given commit is used directly, no rebase/merge
# is performed.
#
# No checkout is done, this should be performed first.
# Assumes we're already in the needed source dir.
# Assumes we're in a clean working directory (use git-stash to achieve
#   if necessary).
#
# First parameter is the commit to update to. This can be in pretty
#     much any format that git itself will respect (e.g. tag, sha1, etc.).
#     It is recommended to use refs/$foo/$bar syntax for specificity.
# Returns boolean success flag.
sub _updateToDetachedHead
{
    my ($self, $commit) = @_;
    my $module = $self->module();

    info ("\tDetaching head to b[$commit]");
    return 0 == log_command($module, 'git-checkout-commit',
                     ['git', 'checkout', $commit]);
}

# Updates an already existing git checkout by running git pull.
#
# Throws an exception on error.
#
# Return parameter is the number of affected *commits*.
sub updateExistingClone
{
    my $self     = assert_isa(shift, 'ksb::Updater::Git');
    my $module   = $self->module();
    my $cur_repo = $module->getOption('repository');
    my $result;

    p_chdir($module->fullpath('source'));

    # Try to save the user if they are doing a merge or rebase
    if (-e '.git/MERGE_HEAD' || -e '.git/rebase-merge' || -e '.git/rebase-apply') {
        croak_runtime ("Aborting git update for $module, you appear to have a rebase or merge in progress!");
    }

    my $remoteName = $self->_setupBestRemote();

    # Download updated objects. This also updates remote heads so do this
    # before we start comparing branches and such.
    info ("Fetching remote changes to g[$module]");
    if (0 != log_command($module, 'git-fetch', ['git', 'fetch', '--tags', $remoteName])) {
        croak_runtime ("Unable to perform git fetch for $remoteName ($cur_repo)");
    }

    # Now we need to figure out if we should update a branch, or simply
    # checkout a specific tag/SHA1/etc.
    my ($commitId, $commitType) = $self->_determinePreferredCheckoutSource($module);
    if ($commitType eq 'none') {
        $commitType = 'branch';
        $commitId = $self->_detectDefaultRemoteHead($remoteName);
    }

    note ("Merging g[$module] changes from $commitType b[$commitId]");
    my $start_commit = $self->commit_id('HEAD');

    my $updateSub;
    if ($commitType eq 'branch') {
        $updateSub = sub { $self->_updateToRemoteHead($remoteName, $commitId) };
    }
    else {
        $updateSub = sub { $self->_updateToDetachedHead($commitId); }
    }

    # With all remote branches fetched, and the checkout of our desired
    # branch completed, we can now use our update sub to complete the
    # changes.
    $self->stashAndUpdate($updateSub);
    return count_command_output('git', 'rev-list', "$start_commit..HEAD");
}

# Tries to determine the best remote branch name to use as a default if the
# user hasn't selected one, by resolving the remote symbolic ref "HEAD" from
# its entry in the .git dir.  This can also be found by introspecting the
# output of "git remote show $REMOTE_NAME" or "git branch -r" but these are
# incredibly slow.
sub _detectDefaultRemoteHead ($self, $remoteName)
{
    croak_internal ("Run " . __SUB__ . " from git repo!")
        unless -d '.git';
    my $data = Mojo::File->new(".git/refs/remotes/$remoteName/HEAD")->slurp;

    my ($head) = ($data // '') =~ m,^ref: *refs/remotes/[^/]+/([^/]+)$,;
    croak_runtime ("Can't find HEAD for remote $remoteName")
        unless $head;

    chomp($head);
    return $head;
}

# Goes through all the various combination of git checkout selection options in
# various orders of priority.
#
# Returns a *list* containing: (the resultant symbolic ref/or SHA1,'branch' or
# 'tag' (to determine if something like git-pull would be suitable or whether
# you have a detached HEAD)). Since the sym-ref is returned first that should
# be what you get in a scalar context, if that's all you want.
sub _determinePreferredCheckoutSource
{
    my ($self, $module) = @_;
    $module //= $self->module();

    my @priorityOrderedSources = (
        #   option-name    type   getOption-inheritance-flag
        [qw(commit         tag    module)],
        [qw(revision       tag    module)],
        [qw(tag            tag    module)],
        [qw(branch         branch module)],
        [qw(branch-group   branch module)],
        [qw(use-stable-kde branch module)],
        # commit/rev/tag don't make sense for git as globals
        [qw(branch         branch allow-inherit)],
        [qw(branch-group   branch allow-inherit)],
        [qw(use-stable-kde branch allow-inherit)],
    );

    # For modules that are not actually a 'proj' module we skip branch-group
    # and use-stable-kde entirely to allow for global/module branch selection
    # options to be selected... kind of complicated, but more DWIMy
    if (!$module->scm()->isa('ksb::Updater::KDEProject')) {
        @priorityOrderedSources = grep {
            $_->[0] ne 'branch-group' && $_->[0] ne 'use-stable-kde'
        } @priorityOrderedSources;
    }

    my $checkoutSource;
    # Sorry about the !!, easiest way to be clear that bool context is intended
    my $sourceTypeRef = first {
        !!($checkoutSource = ($module->getOption($_->[0], $_->[2]) // ''))
    } @priorityOrderedSources;

    # The user has no clear desire here (either set for the module or globally.
    # Note that the default config doesn't generate a global 'branch' setting).
    # In this case it's unclear which convention source modules will use between
    # 'master', 'main', or something entirely different.  So just don't guess...
    if (!$sourceTypeRef) {
        whisper ("No branch specified for $module, will use whatever git gives us");
        return qw(none none);
    }

    # One fixup is needed for use-stable-kde, to pull the actual branch name
    # from the right spot. Although if no branch name is set we use master,
    # without trying to search again.
    if ($sourceTypeRef->[0] eq 'use-stable-kde') {
        $checkoutSource = $module->getOption('#branch:stable', 'module') || 'master';
    }

    # Likewise branch-group requires special handling. checkoutSource is
    # currently the branch-group to be resolved.
    if ($sourceTypeRef->[0] eq 'branch-group') {
        assert_isa($self, 'ksb::Updater::KDEProject');
        $checkoutSource = $self->_resolveBranchGroup($checkoutSource);

        if (!$checkoutSource) {
            my $branchGroup = $module->getOption('branch-group');
            whisper ("No specific branch set for $module and $branchGroup, using master!");
            $checkoutSource = 'master';
        }
    }

    if ($sourceTypeRef->[0] eq 'tag' && $checkoutSource !~ m{^refs/tags/}) {
        $checkoutSource = "refs/tags/$checkoutSource";
    }

    return ($checkoutSource, $sourceTypeRef->[1]);
}

# Tries to check whether the git module is using submodules or not. Currently
# we just check the .git/config file (using git-config) to determine whether
# there are any 'active' submodules.
#
# MUST BE RUN FROM THE SOURCE DIR
sub _hasSubmodules
{
    # The git-config line shows all option names of the form submodule.foo.active,
    # filtering down to options for which the option is set to 'true'
    my @configLines = filter_program_output(undef, # accept all lines
        qw(git config --local --get-regexp ^submodule\..*\.active true));
    return scalar @configLines > 0;
}

# Splits a URI up into its component parts. Taken from
# http://search.cpan.org/~ether/URI-1.67/lib/URI.pm
# Copyright Gisle Aas under the following terms:
# "This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself."
sub _splitUri
{
    my($scheme, $authority, $path, $query, $fragment) =
        $_[0] =~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;
    return ($scheme, $authority, $path, $query, $fragment);
}

sub countStash
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    my $description = shift;

    if (-e '.git/refs/stash') {
        my $count = qx"git rev-list --walk-reflogs --count refs/stash";
        chomp $count if $count;
        debug("\tNumber of stashes found for b[$module] is: b[$count]");
        return $count;
    } else {
        debug("\tIt appears there is no stash for b[$module]");
        return 0;
    }
}

#
# Wrapper to send a post-build (warning) message via the IPC object.
# This just takes care of the boilerplate to forward its arguments as message.
#
sub _notifyPostBuildMessage
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    $self->{ipc}->notifyNewPostBuildMessage($module->name(), @_);
}

# This stashes existing changes if necessary, and then runs a provided
# update routine in order to advance the given module to the desired head.
# Finally, if changes were stashed, they are applied and the stash stack is
# popped.
#
# It is assumed that the required remote has been setup already, that we
# are on the right branch, and that we are already in the correct
# directory.
#
# First parameter is a reference to the subroutine to run. This subroutine
# should need no parameters and return a boolean success indicator. It may
# throw exceptions.
#
# Throws an exception on error.
#
# No return value.
sub stashAndUpdate
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $updateSub = shift;
    my $module = $self->module();
    my $date = strftime ("%F-%R", gmtime()); # ISO Date, hh:mm time
    my $stashName = "kdesrc-build auto-stash at $date";

    # first, log a snapshot of the git status prior to kdesrc-build taking over the reins in the repo
    log_command($module, 'git-status-before-update', [qw(git status)]);
    my $oldStashCount = $self->countStash();

    #
    # always stash:
    # - also stash untracked files because what if upstream started to track them
    # - we do not stash .gitignore'd files because they may be needed for builds?
    #   on the other hand that leaves a slight risk if upstream altered those (i.e. no longer truly .gitignore'd)
    #
    whisper ("\tStashing local changes if any...");
    my $status = 0;
    $status = log_command($module, 'git-stash-push', [
        qw(git stash push -u --quiet --message), $stashName
    ]) unless pretending(); # probably best not to do anything if pretending()

    #
    # This might happen if the repo is already in merge conflict state.
    # We could sledgehammer our way past this by marking everything as resolved using git add . before
    # stashing, but... that might not always be appreciated by people having to figure out what the
    # original merge conflicts were afterwards.
    #
    if ($status != 0) {
        log_command($module, 'git-status-after-error', [qw(git status)]);
        $self->_notifyPostBuildMessage(
            "b[$module] may have local changes that we couldn't handle, so the module was left alone."
        );
        croak_runtime("Unable to stash local changes (if any) for $module, aborting update.");
    }

    #
    # next: check if the stash was truly necessary.
    # compare counts (not just testing if there is *any* stash) because there might have been a
    # genuine user's stash already prior to kdesrc-build taking over the reins in the repo.
    #
    my $newStashCount = $self->countStash();

    #
    # mark that we applied a stash so that $updateSub (_updateToRemoteHead or
    # _updateToDetachedHead) can know not to do dumb things
    #
    $module->setOption('#git-was-stashed', 1)
        if $newStashCount != $oldStashCount;

    # finally, update to remote head
    if (!$updateSub->()) {
        error ("\tUnable to update the source code for r[b[$module]");
        log_command($module, 'git-status-after-error', [qw(git status)]);
    }

    #
    # If the stash had been needed then try to re-apply it before we build, so that KDE
    # developers working on changes do not have to manually re-apply.
    #
    if ($newStashCount != $oldStashCount) {
        my $stashResult = log_command($module, 'git-stash-pop', [qw(git stash pop)]);

        if ($stashResult != 0) {
            my $message = "r[b[*] Unable to restore local changes for b[$module]! " .
                "You should manually inspect the new stash: b[$stashName]";
            warning ("\t$message");
            $self->_notifyPostBuildMessage($message);
        } else {
            info ("\tb[*] You had local changes to b[$module], which have been re-applied.");
        }
    }
}

# This subroutine finds an existing remote-tracking branch name for the
# given repository's named remote. For instance if the user was using the
# local remote-tracking branch called 'qt-stable' to track kde-qt's master
# branch, this subroutine would return the branchname 'qt-stable' when
# passed kde-qt and 'master'.
#
# The current directory must be the source directory of the git module.
#
# First parameter : The git remote to use (normally origin).
# Second parameter: The remote head name to find a local branch for.
# Returns: Empty string if no match is found, or the name of the local
#          remote-tracking branch if one exists.
sub getRemoteBranchName
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $remoteName = shift;
    my $branchName = shift;

    # We'll parse git config output to search for branches that have a
    # remote of $remoteName and a 'merge' of refs/heads/$branchName.

    # TODO: Replace with git for-each-ref refs/heads and the %(upstream)
    # format.
    my @branches = slurp_git_config_output(
        qw/git config --null --get-regexp branch\..*\.remote/, $remoteName
    );

    foreach my $gitBranch (@branches) {
        # The key/value is \n separated, we just want the key.
        my ($keyName) = split(/\n/, $gitBranch);
        my ($thisBranch) = ($keyName =~ m/^branch\.(.*)\.remote$/);

        # We have the local branch name, see if it points to the remote
        # branch we want.
        my @configOutput = slurp_git_config_output(
            qw/git config --null/, "branch.$thisBranch.merge"
        );

        if (@configOutput && $configOutput[0] eq "refs/heads/$branchName") {
            # We have a winner
            return $thisBranch;
        }
    }

    return '';
}

#
# Filter for bestRemoteName to determine if a given remote name and url looks
# like a plausible prior existing remote for a given configured repository URL.
#
# Note that the actual repository fetch URL is not necessarily the same as the
# configured (expected) fetch URL: an upstream might have moved, or kdesrc-build
# configuration might have been updated to the same effect.
#
# Arguments:
#   - name : name of the remote found
#   - url : the configured (fetch) URL
#   - configuredURL : the configured URL for the module (the expected fetch URL).
#
# Return value: whether the remote will be conisdered for bestRemoteName
#
sub _isPlausibleExistingRemote
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $name = shift; # not used, subclasses might want to filter on remote name
    my $url = shift;
    my $configuredUrl = shift;
    return $url eq $configuredUrl;
}

# 99% of the time the 'origin' remote will be what we want anyways, and
# 0.5% of the rest the user will have manually added a remote, which we
# should try to utilize when doing checkouts for instance. To aid in this,
# this subroutine returns a list of all remote aliased matching the
# supplied repository (besides the internal alias that is).
#
# Assumes that we are already in the proper source directory.
#
# First parameter: Repository URL to match.
# Returns: A list of matching remote names (list in case the user hates us
# and has aliased more than one remote to the same repo). Obviously the list
# will be empty if no remote names were found.
sub bestRemoteName
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    my $configuredUrl = $module->getOption('repository');
    my @outputs;

    # The Repo URL isn't much good, let's find a remote name to use it with.
    # We'd have to escape the repo URL to pass it to Git, which I don't trust,
    # so we just look for all remotes and make sure the URL matches afterwards.
    eval {
        @outputs = slurp_git_config_output(
            qw/git config --null --get-regexp remote\..*\.url ./
        );
    };

    if ($@) {
        error ("\tUnable to run git config, is there a setup error?");
        return;
    }

    my @results;
    foreach my $output (@outputs) {
        # git config output between key/val is divided by newline.
        my ($remoteName, $url) = split(/\n/, $output);

        $remoteName =~ s/^remote\.//;
        $remoteName =~ s/\.url$//; # remove the cruft

        # Skip other remotes
        next unless $self->_isPlausibleExistingRemote($remoteName, $url, $configuredUrl);

        # Try to avoid "weird" remote names.
        next if $remoteName !~ /^[\w-]*$/;

        # A winner is this one.
        push @results, $remoteName;
    }

    return @results;
}

# Generates a potential new branch name for the case where we have to setup
# a new remote-tracking branch for a repository/branch. There are several
# criteria that go into this:
# * The local branch name will be equal to the remote branch name to match usual
#   Git convention.
# * The name chosen must not already exist. This methods tests for that.
# * The repo name chosen should be (ideally) a remote name that the user has
#   added. If not, we'll try to autogenerate a repo name (but not add a
#   remote!) based on the repository.git part of the URI.
#
# As with nearly all git support functions, we should be running in the
# source directory of the git module.  Don't call this function unless
# you've already checked that a suitable remote-tracking branch doesn't
# exist.
#
# First parameter: The name of a git remote to use.
# Second parameter: The name of the remote head we need to make a branch name
# of.
# Returns: A useful branch name that doesn't already exist, or '' if no
# name can be generated.
sub makeBranchname
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $remoteName = shift || 'origin';
    my $branch = shift;
    my $module = $self->module();
    my $chosenName;

    # Use "$branch" directly if not already used, otherwise try to prefix
    # with the remote name.
    for my $possibleBranch ($branch, "$remoteName-$branch", "ksdc-$remoteName-$branch") {
        my $result = system('git', 'show-ref', '--quiet', '--verify',
            '--', "refs/heads/$possibleBranch") >> 8;

        return $possibleBranch if $result == 1;
    }

    croak_runtime("Unable to find good branch name for $module branch name $branch");
}

# Returns the number of lines in the output of the given command. The command
# and all required arguments should be passed as a normal list, and the current
# directory should already be set as appropriate.
#
# Return value is the number of lines of output.
# Exceptions are raised if the command could not be run.
sub count_command_output
{
    # Don't call with $self->, all args are passed to filter_program_output
    my @args = @_;
    my $count = 0;

    filter_program_output(sub { $count++ if $_ }, @args);
    return $count;
}

# A simple wrapper that is used to split the output of 'git config --null'
# correctly. All parameters are then passed to filter_program_output (so look
# there for help on usage).
sub slurp_git_config_output
{
    # Don't call with $self->, all args are passed to filter_program_output
    local $/ = "\000"; # Split on null

    # This gets rid of the trailing nulls for single-line output. (chomp uses
    # $/ instead of hardcoding newline
    chomp(my @output = filter_program_output(undef, @_)); # No filter
    return @output;
}

# Returns true if the git module in the current directory has a remote of the
# name given by the first parameter.
sub hasRemote
{
    my ($self, $remote) = @_;
    my $hasRemote = 0;

    eval {
        filter_program_output(sub { $hasRemote ||= ($_ && /^$remote/) }, 'git', 'remote');
    };

    return $hasRemote;
}

# Subroutine to add the 'kde:' alias to the user's git config if it's not
# already set.
#
# Call this as a static class function, not as an object method
# (i.e. ksb::Updater::Git::verifyGitConfig, not $foo->verifyGitConfig)
#
# Returns false on failure of any sort, true otherwise.
sub verifyGitConfig
{
    my $contextOptions = shift;
    my $protocol = $contextOptions->getOption('git-desired-protocol') || 'git';

    my $pushUrlPrefix = '';
    my $otherPushUrlPrefix = '';

    if ($protocol eq 'git' || $protocol eq 'https') {
        $pushUrlPrefix = $protocol eq 'git' ? 'ssh://git@invent.kde.org/' : 'https://invent.kde.org/';
        $otherPushUrlPrefix = $protocol eq 'git' ? 'https://invent.kde.org/' : 'ssh://git@invent.kde.org/';
    }
    else {
        error(" b[y[*] Invalid b[git-desired-protocol] $protocol");
        error(" b[y[*] Try setting this option to 'git' if you're not using a proxy");
        croak_runtime("Invalid git-desired-protocol: $protocol");
    }

    my $configOutput =
        qx'git config --global --get url.https://invent.kde.org/.insteadOf kde:';

    # 0 means no error, 1 means no such section exists -- which is OK
    if ((my $errNum = $? >> 8) >= 2) {
        my $error = "Code $errNum";
        my %errors = (
            3   => 'Invalid config file (~/.gitconfig)',
            4   => 'Could not write to ~/.gitconfig',
            2   => 'No section was provided to git-config',
            1   => 'Invalid section or key',
            5   => 'Tried to set option that had no (or multiple) values',
            6   => 'Invalid regexp with git-config',
            128 => 'HOME environment variable is not set (?)',
        );

        $error = $errors{$errNum} if exists $errors{$errNum};
        error (" r[*] Unable to run b[git] command:\n\t$error");
        return 0;
    }

    # If we make it here, I'm just going to assume git works from here on out
    # on this simple task.
    if ($configOutput !~ /^kde:\s*$/) {
        whisper ("\tAdding git download kde: alias (fetch: https://invent.kde.org/)");
        my $result = safe_system(
            qw(git config --global --add url.https://invent.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    $configOutput =
        qx"git config --global --get url.$pushUrlPrefix.pushInsteadOf kde:";

    if ($configOutput !~ /^kde:\s*$/) {
        whisper ("\tAdding git upload kde: alias (push: $pushUrlPrefix)");
        my $result = safe_system('git', 'config', '--global', '--add', "url.$pushUrlPrefix.pushInsteadOf", 'kde:') >> 8;
        return 0 if $result != 0;
    }

    # Remove old kdesrc-build installed aliases (kde: -> git://anongit.kde.org/)
    $configOutput =
        qx'git config --global --get url.git://anongit.kde.org/.insteadOf kde:';

    if ($configOutput =~ /^kde:\s*$/) {
        whisper ("\tRemoving outdated kde: alias (fetch: git://anongit.kde.org/)");
        my $result = safe_system(
            qw(git config --global --unset-all url.git://anongit.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    $configOutput =
        qx'git config --global --get url.https://anongit.kde.org/.insteadOf kde:';

    if ($configOutput =~ /^kde:\s*$/) {
        whisper ("\tRemoving outdated kde: alias (fetch: https://anongit.kde.org/)");
        my $result = safe_system(
            qw(git config --global --unset-all url.https://anongit.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    $configOutput =
        qx'git config --global --get url.git@git.kde.org:.pushInsteadOf kde:';

    if ($configOutput =~ /^kde:\s*$/) {
        whisper ("\tRemoving outdated kde: alias (push: git\@git.kde.org)");
        my $result = safe_system(
            qw(git config --global --unset-all url.git@git.kde.org:.pushInsteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    # remove outdated alias if git-desired-protocol gets flipped

    $configOutput =
        qx"git config --global --get url.$otherPushUrlPrefix.pushInsteadOf kde:";

    if ($configOutput =~ /^kde:\s*$/) {
        whisper ("\tRemoving outdated kde: alias (push: $otherPushUrlPrefix)");
        my $result = safe_system('git', 'config', '--global', '--unset-all', "url.$otherPushUrlPrefix.pushInsteadOf", 'kde:') >> 8;
        return 0 if $result != 0;
    }

    return 1;
}

1;
