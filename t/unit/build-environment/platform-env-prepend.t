# Test that empty install-dir and/or qt-install-dir do not cause empty /bin settings to be
# configured in environment.

use ksb;
use Test::More;
use POSIX;
use File::Basename;

use ksb::DependencyResolver;
use ksb::BuildContext;
use ksb::Module;

# <editor-fold desc="Begin collapsible section">
my $timestamp1 = POSIX::strftime("%s", localtime);
my $filename = basename(__FILE__);
my $section_header = "File: $filename (click to toggle collapse)";
print "\e[0Ksection_start:${timestamp1}:$filename\[collapsed=true]\r\e[0K$section_header\n";  # displayed in collapsible section in gitlab ci job log
# </editor-fold>

my $ctx = ksb::BuildContext->new;

sub no_bare_bin
{
    my @elem = split(':', shift);
    return ! (grep { $_ eq '/bin' } @elem);
}

{
    my $mod = ksb::Module->new($ctx, 'test');
    my $newPath = $ENV{PATH};
    $newPath =~ s(^/bin:)()g; # Remove existing bare /bin entries if present
    $newPath =~ s(:/bin$)()g;
    $newPath =~ s(:/bin:)()g;
    local $ENV{PATH} = $newPath;

    $ctx->setOption('install-dir', ''); # must be set but empty
    $ctx->setOption('qt-install-dir', '/dev/null');

    $mod->setupEnvironment();

    ok(exists $ctx->{env}->{PATH}, "Entry created for PATH when setting up mod env");
    ok(no_bare_bin($ctx->{env}->{PATH}), "/bin wasn't prepended to PATH")
        or diag explain $ctx->{env}->{PATH};
}

$ctx->resetEnvironment();

{
    my $mod = ksb::Module->new($ctx, 'test');
    my $newPath = $ENV{PATH};
    $newPath =~ s(^/bin:)()g; # Remove existing bare /bin entries if present
    $newPath =~ s(:/bin$)()g;
    $newPath =~ s(:/bin:)()g;
    local $ENV{PATH} = $newPath;

    $ctx->setOption('qt-install-dir', ''); # must be set but empty
    $ctx->setOption('install-dir', '/dev/null');

    $mod->setupEnvironment();

    ok(exists $ctx->{env}->{PATH}, "Entry created for PATH when setting up mod env");
    ok(no_bare_bin($ctx->{env}->{PATH}), "/bin wasn't prepended to PATH")
        or diag explain $ctx->{env}->{PATH};
}

$ctx->resetEnvironment();

{
    my $mod = ksb::Module->new($ctx, 'test');
    my $newPath = $ENV{PATH};
    $newPath =~ s(^/bin:)()g; # Remove existing bare /bin entries if present
    $newPath =~ s(:/bin$)()g;
    $newPath =~ s(:/bin:)()g;
    local $ENV{PATH} = $newPath;

    $ctx->setOption('qt-install-dir', '/dev/null');
    $ctx->setOption('install-dir', '/dev/null');

    $mod->setupEnvironment();

    ok(exists $ctx->{env}->{PATH}, "Entry created for PATH when setting up mod env");
    ok(no_bare_bin($ctx->{env}->{PATH}), "/bin wasn't prepended to PATH")
        or diag explain $ctx->{env}->{PATH};
}

# Ensure binpath and libpath options work

$ctx->resetEnvironment();

{
    my $mod = ksb::Module->new($ctx, 'test');
    local $ENV{PATH} = '/bin:/usr/bin';

    $ctx->setOption('binpath', '/tmp/fake/bin');
    $ctx->setOption('libpath', '/tmp/fake/lib:/tmp/fake/lib64');

    $mod->setupEnvironment();

    ok($ctx->{env}->{PATH} =~ m(/tmp/fake/bin), 'Ensure `binpath` present in generated PATH');
    ok($ctx->{env}->{LD_LIBRARY_PATH} =~ m(/tmp/fake/lib),
        'Ensure `libpath` present in generated LD_LIBRARY_PATH');
}

# <editor-fold desc="End collapsible section">
my $timestamp2 = POSIX::strftime("%s", localtime);
print "\e[0Ksection_end:${timestamp2}:$filename\r\e[0K\n";  # close collapsible section
# </editor-fold>

done_testing();
