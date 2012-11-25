package ksb::Updater::Git;

# Module which is responsible for updating git-based source code modules. Can
# have some features overridden by subclassing (see ksb::Updater::KDEProject
# for an example).

use ksb::Debug;
use ksb::Util;
use ksb::Updater;

our @ISA = qw(ksb::Updater);

use File::Basename; # basename
use File::Spec;     # tmpdir
use POSIX qw(strftime);
use List::Util qw(first);

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

# Perform a git clone to checkout the latest branch of a given git module
#
# First parameter is the repository (typically URL) to use.
# Returns boolean true if successful, false otherwise.
sub clone
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $git_repo = shift;
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my @args = ('--', $git_repo, $srcdir);

    # The -v forces progress output from git, which seems to work around either
    # a gitorious.org bug causing timeout errors after cloning large
    # repositories (such as Qt...)
    if ($module->buildSystemType() eq 'Qt' &&
        $module->buildSystem()->forceProgressOutput())
    {
        unshift (@args, '-v');
    }

    note ("Cloning g[$module]");

    my $result = ($self->installGitSnapshot()) ||
                 0 == log_command($module, 'git-clone', ['git', 'clone', @args]);

    if ($result) {
        $module->setPersistentOption('git-cloned-repository', $git_repo);

        my $branch = $self->getBranch();
        p_chdir($srcdir);

        # Switch immediately to user-requested tag or branch now.
        if (my $rev = $module->getOption('revision')) {
            info ("\tSwitching to specific revision g[$rev]");
            $result = (log_command($module, 'git-checkout-rev',
                ['git', 'checkout', $rev]) == 0);
        }
        elsif (my $tag = $module->getOption('tag')) {
            info ("\tSwitching to specific tagged-commit g[$tag]");
            $result = (log_command($module, 'git-checkout-tag',
                ['git', 'checkout', "refs/tags/$tag"]) == 0);
        }
        elsif ((my $branch = $self->getBranch()) ne 'master') {
            info ("\tSwitching to branch g[$branch]");
            $result = (log_command($module, 'git-checkout',
                ['git', 'checkout', '-b', $branch, "origin/$branch"]) == 0);
        }
    }

    return ($result != 0);
}

# Either performs the initial checkout or updates the current git checkout
# for git-using modules, as appropriate.
#
# If errors are encountered, an exception is raised using die().
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
        # Check if an existing source directory is there somehow.
        if (-e "$srcdir") {
            if ($module->getOption('#delete-my-patches')) {
                warning ("\tRemoving conflicting source directory " .
                         "as allowed by --delete-my-patches");
                warning ("\tRemoving b[$srcdir]");
                main::safe_rmtree($srcdir) or do {
                    die "Unable to delete r[b[$srcdir]!";
                };
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

                die ('Conflicting source-dir present');
            }
        }

        my $git_repo = $module->getOption('repository');

        if (!$git_repo) {
            die "Unable to checkout $module, you must specify a repository to use.";
        }

        $self->clone($git_repo) or die "Can't checkout $module: $!";

        return 1 if pretending();
        return count_command_output('git', '--git-dir', "$srcdir/.git", 'ls-files');
    }

    return 0;
}

# Selects a git remote for the user's selected repository (preferring a
# defined remote if available, using 'origin' otherwise).
#
# Assumes the current directory is already set to the source directory.
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
                die "Unable to update the fetch URL for existing remote alias for $module";
            }
        }
        elsif (log_command($module, 'git-remote-setup',
                       ['git', 'remote', 'add', DEFAULT_GIT_REMOTE, $cur_repo])
            != 0)
        {
            die "Unable to add a git remote named " . DEFAULT_GIT_REMOTE . " for $cur_repo";
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
        $module->setPersistentOption('git-cloned-repository', $cur_repo);
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
            die "Unable to perform a git checkout of $remoteName/$branch to a local branch of $newName";
        }
    }
    else {
        whisper ("\tUpdating g[$module] using existing branch g[$branchName]");
        if (0 != log_command($module, 'git-checkout-update',
                      ['git', 'checkout', $branchName]))
        {
            die "Unable to perform a git checkout to existing branch $branchName";
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
# Return parameter is the number of affected *commits*. Errors are
# returned only via exceptions because of this.
sub updateExistingClone
{
    my $self     = assert_isa(shift, 'ksb::Updater::Git');
    my $module   = $self->module();
    my $cur_repo = $module->getOption('repository');
    my $result;

    p_chdir($module->fullpath('source'));

    my $remoteName = $self->_setupBestRemote();

    # Download updated objects. This also updates remote heads so do this
    # before we start comparing branches and such.
    info ("Downloading updates for g[$module]");
    if (0 != log_command($module, 'git-fetch', ['git', 'fetch', $remoteName])) {
        die "Unable to perform git fetch for $remoteName, which should be $cur_repo";
    }

    # Now we need to figure out if we should update a branch, or simply
    # checkout a specific tag/SHA1/etc.
    # We need to be wordy here to placate the Perl warning generator.
    my @gitRefTypes = (
        [qw/revision commit/], [qw/tag tag/],
    );
    my $gitRefType = (first { $module->getOption($_->[0]) } @gitRefTypes) //
                      ['branch', 'branch'];
    my ($chosenRefOption, $type) = @$gitRefType;

    my $branch = $type eq 'branch' ? $self->getBranch()
                                   : $module->getOption($chosenRefOption);

    note ("Updating g[$module] (to $type b[$branch])");
    my $start_commit = $self->commit_id('HEAD');

    my $updateSub = sub { $self->_updateToRemoteHead($remoteName, $branch) };
    if ($type ne 'branch') {
        $branch = "refs/tags/$branch" if $type eq 'tag';
        $updateSub = sub { $self->_updateToDetachedHead($branch); }
    }

    # With all remote branches fetched, and the checkout of our desired
    # branch completed, we can now use our update sub to complete the
    # changes.
    if ($self->stashAndUpdate($updateSub)) {
        return count_command_output('git', 'rev-list', "$start_commit..HEAD");
    }
    else {
        # We must throw an exception if we fail.
        die "Unable to update $module";
    }
}

# Returns the user-selected branch for the given module, or 'master' if no
# branch was selected.
#
# First parameter is the module name.
sub getBranch
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    my $branch = $module->getOption('branch');

    if (!$branch && $module->getOption('use-stable-kde')) {
        my $stable = $module->getOption('#branch:stable');
        if ($stable && $stable ne 'none') {
            $branch = $stable;
        }
    }

    $branch ||= 'master'; # If no branch, use 'master'
    return $branch;
}

# Attempts to download and install a git snapshot for the given Module.
# This requires the module to have the '#snapshot-tarball' option set,
# normally done after KDEXMLReader is used to parse the projects.kde.org
# XML database.  This function should be called with the current directory
# set to the source directory.
#
# After installing the tarball, an immediate git pull will be run to put the
# module up-to-date. The branch is not updated however!
#
# The user can cause this function to fail by setting the disable-snapshots
# option for the module (either at the command line or in the rc file).
#
# Returns boolean true on success, false otherwise.
sub installGitSnapshot
{
    my $self = assert_isa(shift, 'ksb::Updater::Git');
    my $module = $self->module();
    my $tarball = $module->getOption('#snapshot-tarball');

    return 0 if $module->getOption('disable-snapshots');
    return 0 unless $tarball;

    if (pretending()) {
        pretend ("\tWould have downloaded snapshot for g[$module], from");
        pretend ("\tb[g[$tarball]");
        return 1;
    }

    info ("\tDownloading git snapshot for g[$module]");

    my $filename = basename(URI->new($tarball)->path());
    my $tmpdir = File::Spec->tmpdir() // "/tmp";
    $filename = "$tmpdir/$filename"; # Make absolute

    if (!download_file($tarball, $filename, $module->getOption('http-proxy'))) {
        error ("Unable to download snapshot for module r[$module]");
        return 0;
    }

    info ("\tDownload complete, preparing module source code");

    # It would be possible to use Archive::Tar, but it's apparently fairly
    # slow. In addition we need to use -C and --strip-components (which are
    # also supported in BSD tar, perhaps not Solaris) to ensure it's extracted
    # in a known location. Since we're using "sufficiently good" tar programs
    # we can take advantage of their auto-decompression.
    my $sourceDir = $module->fullpath('source');
    super_mkdir($sourceDir);

    my $result = safe_system(qw(tar --strip-components 1 -C),
                          $sourceDir, '-xf', $filename);
    my $savedError = $!; # Avoid interference from safe_unlink
    safe_unlink ($filename);

    if ($result) {
        error ("Unable to extract snapshot for r[b[$module]: $savedError");
        main::safe_rmtree($sourceDir);
        return 0;
    }

    whisper ("\tg[$module] snapshot is in place");

    # Complete the preparation by running the initrepo.sh script
    p_chdir($sourceDir);
    $result = log_command($module, 'init-git-repo', ['/bin/sh', './initrepo.sh']);

    if ($result) {
        error ("Snapshot for r[$module] extracted successfully, but failed to complete initrepo.sh");
        main::safe_rmtree($sourceDir);
        return 0;
    }

    whisper ("\tConverting to kde:-style URL");
    $result = log_command($module, 'fixup-git-remote',
        ['git', 'remote', 'set-url', 'origin', "kde:$module"]);

    if ($result) {
        warning ("\tUnable to convert origin URL to kde:-style URL. Things should");
        warning ("\tstill work, you may have to adjust push URL manually.");
    }

    info ("\tGit snapshot installed, now bringing up to date.");
    $result = log_command($module, 'init-git-pull', ['git', 'pull']);
    return ($result == 0);
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
# Returns true on success, false otherwise. Some egregious errors result in
# exceptions being thrown however.
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
    if ($status) {
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
        info ("\tLocal changes detected, stashing them away...");
        $status = log_command($module, 'git-stash-save', [
                qw(git stash save --quiet), "kdesrc-build auto-stash at $date",
            ]);
        if ($status != 0) {
            croak_runtime("Unable to stash local changes for $module, aborting update.");
        }
    }

    if (!$updateSub->()) {
        error ("Unable to update the source code for r[b[$module]");
        return 0;
    }

    # Update is performed and successful, re-apply the stashed changes
    if ($needsStash) {
        info ("\tModule updated, reapplying your local changes.");
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
* to re-apply was y[git stash --pop --index]. Resolve this before you run
* kdesrc-build to update this module again.
*
* If you do not desire to keep your local changes, then you can generally run
* r[b[git reset --hard HEAD], or simply delete the source directory for
* $module. Developers be careful, doing either of these options will remove
* any of your local work.
EOF
            return 0;
        }
    }

    return 1;
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
        error ("Unable to run git config, is there a setup error?");
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
        my $result = safe_system('git', 'show-ref', '--quiet', '--verify',
            '--', "/refs/heads/$possibleBranch");

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
        qx'git config --global --get url.git://anongit.kde.org/.insteadOf kde:';

    # 0 means no error, 1 means no such section exists -- which is OK
    if ((my $errNum = $? >> 8) >= 2) {
        my $error = "Code $errNum";
        my %errors = (
            3   => 'Invalid config file (~/.gitconfig)',
            4   => 'Could not write to ~/.gitconfig',
            128 => 'HOME environment variable is not set (?)',
        );

        $error = $errors{$errNum} if exists $errors{$errNum};
        error (" r[*] Unable to run b[git] command:\n\t$error");
        return 0;
    }

    # If we make it here, I'm just going to assume git works from here on out
    # on this simple task.
    if ($configOutput !~ /^kde:\s*$/) {
        info ("\tAdding git download kde: alias");
        my $result = safe_system(
            qw(git config --global --add url.git://anongit.kde.org/.insteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    $configOutput =
        qx'git config --global --get url.git@git.kde.org:.pushInsteadOf kde:';

    if ($configOutput !~ /^kde:\s*$/) {
        info ("\tAdding git upload kde: alias");
        my $result = safe_system(
            qw(git config --global --add url.git@git.kde.org:.pushInsteadOf kde:)
        ) >> 8;
        return 0 if $result != 0;
    }

    return 1;
}

1;
