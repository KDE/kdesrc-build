package ksb::Version;

use ksb;

=head1 DESCRIPTION

This package is just a place to put the kdesrc-build version number
in one spot so it only needs changed in one place for a version bump.

=cut

use IPC::Cmd qw(run can_run);

# It is expected that future git tags will be in the form 'YY.MM' and will
# be time-based instead of event-based as with previous releases.
our $VERSION = '22.01';

my $SCRIPT_PATH = ''; # For auto git-versioning

our $SCRIPT_VERSION = $VERSION;

use Exporter qw(import);
our @EXPORT = qw(scriptVersion);

=head1 FUNCTIONS

=cut

=head2 setBasePath

Should be called before using C<scriptVersion> to set the base path for the
script.  This is needed to auto-detect the version in git for kdesrc-build
instances running from a git repo.

=cut

sub setBasePath ($newPath)
{
    $SCRIPT_PATH = $newPath // $SCRIPT_PATH;
}

=head2 scriptVersion

Call this function to return the kdesrc-build version.

 my $version = scriptVersion(); # '22.07';

If the script is running from within its git repository (and C<setBasePath> has
been called), this function will try to auto-detect the git SHA1 ID of the
current checkout and append the ID (in C<git-describe> format) to the output
string as well.

=cut

sub scriptVersion :prototype()
{
    if ($SCRIPT_PATH && can_run('git') && -d "$SCRIPT_PATH/.git") {
        my ($ok, $err_msg, undef, $stdout) = IPC::Cmd::run(
            command => ['git', "--git-dir=$SCRIPT_PATH/.git", 'describe'],
            verbose => 0);
        my $output = $stdout->[0] // '';
        chomp $output;
        return "$SCRIPT_VERSION ($output)" if ($ok and $output);
    }

    return $SCRIPT_VERSION;
}

1;
