package ksb::Updater::Git 0.15;

# Module which is responsible for updating git-based source code modules. Can
# have some features overridden by subclassing (see ksb::Updater::KDEProject
# for an example).

use strict;
use warnings;
use 5.014;

use parent qw(ksb::Updater);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

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

    return $self->updateCheckout();
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
    my ($commitId, $commitType) = $self->_determinePreferredCheckoutSource($module);

    return 1 if pretending();

    my $ref = $commitId;

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

    note ("Cloning g[$module]");

    p_chdir($module->getSourceDir());

    my ($commitId, $commitType) = $self->_determinePreferredCheckoutSource($module);
    $commitId =~ s,^refs/tags/,,;   # git-clone -b doesn't like refs/tags/
    unshift @args, '-b', $commitId; # Checkout branch right away

    if (0 != log_command($module, 'git-clone', ['git', 'clone', @args])) {
        croak_runtime("Failed to make initial clone of $module");
    }

    #$ipc->notifyPersistentOptionChange($module->name(), 'git-cloned-repository', $git_repo);

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

    # Search for an existing remote name first. If none, add our alias.
    my @remoteNames = $self->bestRemoteName($cur_repo);

    if (!@remoteNames) {
        # The desired repo doesn't have a named remote, this should be
        # because the user switched it in the rc-file. We control the
        # 'origin' remote to fix this.
        if ($self->hasRemote(DEFAULT_GIT_REMOTE)) {
            if (log_command($module, 'git-update-remote',
                        ['git', 'remote', 'set-url', DEFAULT_GIT_REMOTE, $cur_repo])
                != 0)
            {
                croak_runtime("Unable to update the fetch URL for existing remote alias for $module");
            }
        }
        elsif (log_command($module, 'git-remote-setup',
                       ['git', 'remote', 'add', DEFAULT_GIT_REMOTE, $cur_repo])
            != 0)
        {
            croak_runtime("Unable to add a git remote named " . DEFAULT_GIT_REMOTE . " for $cur_repo");
        }

        push @remoteNames, DEFAULT_GIT_REMOTE;
    }

    # Make a notice if the repository we're using has moved.
    my $old_repo = $module->getPersistentOption('git-cloned-repository');
    if ($old_repo and ($cur_repo ne $old_repo)) {
        note (" y[b[*]\ty[$module]'s selected repository has changed");
        note (" y[b[*]\tfrom y[$old_repo]");
        note (" y[b[*]\tto   b[$cur_repo]");
        note (" y[b[*]\tThe git remote named b[", DEFAULT_GIT_REMOTE, "] has been updated");

        # Update what we think is the current repository on-disk.
        #$ipc->notifyPersistentOptionChange($module->name(), 'git-cloned-repository', $cur_repo);
    }

    return $remoteNames[0];
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

        # On the right branch, merge in changes.
        return 0 == log_command($module, 'git-rebase',
                      ['git', 'rebase', "$remoteName/$branch"]);
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
    if (0 != log_command($module, 'git-fetch', ['git', 'fetch', '--tags', $remoteName])) {
        croak_runtime ("Unable to perform git fetch for $remoteName ($cur_repo)");
    }

    # Now we need to figure out if we should update a branch, or simply
    # checkout a specific tag/SHA1/etc.
    my ($commitId, $commitType) = $self->_determinePreferredCheckoutSource($module);

    note ("Updating (to $commitType b[$commitId])")
        if ($commitType ne 'branch' || $commitId ne 'master');
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

    if (!$sourceTypeRef) {
        return qw(master branch);
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

    # To find out if we should stash, we just use git diff --quiet, twice to
    # account for the index and the working dir.
    # Note: Don't use safe_system, as the error code is stripped to the exit code
    my $status = pretending() ? 0 : system('git', 'diff', '--quiet');

    if ($status == -1 || $status & 127) {
        croak_runtime("$module doesn't appear to be a git module.");
    }

    my $needsStash = 0;
    if ($status && !_hasSubmodules()) {
        # There are local changes.
        $needsStash = 1;
    }
    else {
        $status = pretending() ? 0 : system('git', 'diff', '--cached', '--quiet');
        if ($status == -1 || $status & 127) {
            croak_runtime("$module doesn't appear to be a git module.");
        }
        else {
            $needsStash = ($status != 0);
        }
    }

    if ($needsStash) {
        info ("\tLocal changes detected (will stash for now and then restore)");
        $status = log_command($module, 'git-stash-save', [
                qw(git stash save --quiet), "kdesrc-build auto-stash at $date",
            ]);
        if ($status != 0) {
            croak_runtime("Unable to stash local changes for $module, aborting update.");
        }
    }

    if (!$updateSub->()) {
        error ("\tUnable to update the source code for r[b[$module]");
        return;
    }

    # Update is performed and successful, re-apply the stashed changes
    if ($needsStash) {
        $status = log_command($module, 'git-stash-pop', [
                qw(git stash pop --index --quiet)
            ]);
        if ($status != 0) {
            error (<<EOF);
r[b[*]
r[b[*] Unable to re-apply stashed changes to r[b[$module]!
r[b[*]
* These changes were saved using the name "kdesrc-build auto-stash at $date"
* and should still be available using the name stash\@{0}, the command run
* to re-apply was y[git stash pop --index]. Resolve this before you run
* kdesrc-build to update this module again.
*
* If you do not desire to keep your local changes, then you can generally run
* r[b[git reset --hard HEAD], or simply delete the source directory for
* $module. Developers be careful, doing either of these options will remove
* any of your local work.
EOF
            croak_runtime("Failed to re-apply stashed changes for $module");
        }
    }

    return;
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
    my $repoUrl = shift;
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
        $remoteName =~ s/\.url$//; # Extract the cruft

        # Skip other remotes
        next if $url ne $repoUrl;

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
    my $configOutput =
        qx'git config --global --get url.https://anongit.kde.org/.insteadOf kde:';

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
        whisper ("\tAdding git download kde: alias");
        my $result = safe_system(
            qw(git config --global --add url.https://anongit.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    $configOutput =
        qx'git config --global --get url.git@git.kde.org:.pushInsteadOf kde:';

    if ($configOutput !~ /^kde:\s*$/) {
        whisper ("\tAdding git upload kde: alias");
        my $result = safe_system(
            qw(git config --global --add url.git@git.kde.org:.pushInsteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    # Remove old kdesrc-build installed aliases (kde: -> git://anongit.kde.org/)
    $configOutput =
        qx'git config --global --get url.git://anongit.kde.org/.insteadOf kde:';

    if ($configOutput =~ /^kde:\s*$/) {
        whisper ("\tRemoving outdated kde: alias");
        my $result = safe_system(
            qw(git config --global --unset-all url.git://anongit.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    return 1;
}

1;
