# Verify that test kde-project data still results in workable build.

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::Application;
use ksb::Module;

my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log

# The file has a module-set that only refers to juk but should expand to
# kcalc juk in that order
my @args = qw(--pretend --rc-file t/data/kde-projects/kdesrc-buildrc-with-deps);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 3, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'kcalc', 'Right order: kcalc before juk (test dep data)');
    is ($moduleList[1]->name(), 'juk', 'Right order: juk after kcalc (test dep data)');
    is ($moduleList[2]->name(), 'kdesrc-build', 'Right order: dolphin after juk (implicit order)');
    is ($moduleList[0]->getOption('tag'), 'tag-setmod2', 'options block works for indirect reference to kde-projects module');
    is ($moduleList[0]->getOption('cmake-generator'), 'Ninja', 'Global opts seen even with other options');
    is ($moduleList[1]->getOption('cmake-generator'), 'Make', 'options block works for kde-projects module-set');
    is ($moduleList[1]->getOption('cmake-options'), '-DSET_FOO:BOOL=ON', 'module options block can override set options block');
    is ($moduleList[2]->getOption('cmake-generator'), 'Make', 'options block works for kde-projects module-set after options');
    is ($moduleList[2]->getOption('cmake-options'), '-DSET_FOO:BOOL=ON', 'module-set after options can override options block');
}

my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section

done_testing();
