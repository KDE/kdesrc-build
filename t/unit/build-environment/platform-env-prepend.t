use v5.22;
use strict;
use warnings;

# Test that empty kdedir and/or qtdir do not cause empty /bin settings to be
# configured in environment.

use Test::More;

use ksb::DependencyResolver;
use ksb::BuildContext;
use ksb::Module;

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

    $ctx->setOption('kdedir', ''); # must be set but empty
    $ctx->setOption('qtdir', '/dev/null');

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

    $ctx->setOption('qtdir', ''); # must be set but empty
    $ctx->setOption('kdedir', '/dev/null');

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

    $ctx->setOption('qtdir', '/dev/null');
    $ctx->setOption('kdedir', '/dev/null');

    $mod->setupEnvironment();

    ok(exists $ctx->{env}->{PATH}, "Entry created for PATH when setting up mod env");
    ok(no_bare_bin($ctx->{env}->{PATH}), "/bin wasn't prepended to PATH")
        or diag explain $ctx->{env}->{PATH};
}

done_testing();
