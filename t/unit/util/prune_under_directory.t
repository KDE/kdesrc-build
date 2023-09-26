# Test prune_under_directory_p, including ability to remove read-only files in
# sub-tree

use ksb;
use ksb::Util qw(prune_under_directory_p);
use ksb::BuildContext;
use Mojo::File qw(path);

use Test::More;
use File::Temp;

my $dir = path(File::Temp->newdir('kdesrc-build-testXXXXXX'));
ok($dir, 'tempdir created');

my $file = path($dir, 'a')->touch;
ok(-e $file, 'first file created');

my $change_count = chmod 0444, "$file";
ok($change_count == 1, 'Changed mode to readonly');

my $ctx = ksb::BuildContext->new();
$ctx->setOption('log-dir', $dir->to_abs);
my $promise = prune_under_directory_p($ctx, $dir->to_abs);

# This shouldn't disappear until we let the promise start!
ok(-e $file, 'prune_under_directory_p does not start until we let promise run');

$promise->wait;

ok(! -e $file, 'Known read-only file removed');

my @files = $dir->list_tree->each;
ok(@files == 0, "entire directory $dir removed")
    or diag ("Files in temp dir: ", join(', ', @files));

done_testing();
