# Verify that _getDependencyPathOf() works properly

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::DependencyResolver;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

# Redefine ksb::Module to stub fullProjectPath() results
package ksb::Module {
    no warnings 'redefine';

    sub new
    {
        my ($class, $projectPath, $kde) = @_;

        my $self = {
            projectPath => $projectPath,
            kde => $kde
        };

        bless $self, $class;
        return $self;
    }

    sub isKDEProject
    {
        my $self = shift;
        return $self->{kde};
    }

    sub fullProjectPath
    {
        my $self = shift;
        return $self->{projectPath};
    }
};

my $module1 = ksb::Module->new('test/path', 1);

is(ksb::DependencyResolver::_getDependencyPathOf($module1, 'foo', 'bar'), 'test/path', "should return full project path if a KDE module object is passed");

my $module2 = undef;

is(ksb::DependencyResolver::_getDependencyPathOf($module2, 'foo', 'bar'), 'bar', "should return the provided default if no module is passed");

my $module3 = ksb::Module->new('test/path', 0);
is(ksb::DependencyResolver::_getDependencyPathOf($module3, 'foo', 'bar'), 'third-party/test/path', "should return 'third-party/' prefixed project path if a non-KDE module object is passed");

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();

