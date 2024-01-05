# Test safe_lndir_p

use ksb;
use ksb::Util qw(safe_lndir_p);
use Mojo::File qw(path);

use Test::More;
use File::Temp;
use POSIX;
use File::Basename;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

my $dir = path(File::Temp->newdir('kdesrc-build-testXXXXXX'));
ok($dir, 'tempdir created');

my $file = path($dir, 'a')->touch;
ok(-e $file, 'first file created');

my $dir2 = path($dir, 'b/c')->make_path;
ok(-d "$dir/b/c", 'dir created');

my $file2 = path($dir, 'b', 'c', 'file2')->touch;
ok(-e "$dir/b/c/file2", 'second file created');

my $to = path(File::Temp->newdir('kdesrc-build-test2XXXXXX'));
my $promise = safe_lndir_p($dir->to_abs, $to->to_abs);

# These shouldn't exist until we let the promise start!
ok(! -e '$to/b/c/file2', 'safe_lndir does not start until we let promise run');

$promise->wait;

ok(-d "$to/b/c", 'directory symlinked over');
ok(-l "$to/a", 'file under directory is a symlink');
ok(-e "$to/a", 'file under directory exists');
ok(! -e "$to/b/d/file3", 'nonexistent file does not exist');
ok(-l "$to/b/c/file2", 'file2 under directory is a symlink');
ok(-e "$to/b/c/file2", 'file2 under directory exists');

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
