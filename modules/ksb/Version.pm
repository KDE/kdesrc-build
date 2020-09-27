package ksb::Version;

# Pretty much just records the program-wide version number...

use strict;
use warnings;
use v5.22;

use IPC::Cmd qw(run can_run);

# It is expected that future git tags will be in the form 'YY.MM' and will
# be time-based instead of event-based as with previous releases.
our $VERSION = '20.06';

my $SCRIPT_PATH = ''; # For auto git-versioning

our $SCRIPT_VERSION = $VERSION;

use Exporter qw(import);
our @EXPORT = qw(scriptVersion);

sub path
{
    my ($self, $newPath) = @_;
    $SCRIPT_PATH = $newPath // $SCRIPT_PATH;
}

sub scriptVersion()
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
