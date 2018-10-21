package ksb::OSSupport 0.10;

use 5.014;
use strict;
use warnings;

use ksb::Util qw(croak_runtime);

use Text::ParseWords qw(nested_quotewords);
use List::Util qw(first);

=head1 NAME

ksb::OSSupport

=head1 DESCRIPTION

Provides support code for handling distro-specific functionality, such as lists
of package dependencies, command lines to update packages in the first place,
and so on.

See L<https://www.freedesktop.org/software/systemd/man/os-release.html> for the
relevant specification.

=head1 SYNOPSIS

    my $os = ksb::OSSupport->new; # Autodetects info on running system
    say "Current OS is: ", $os->vendorID;

=cut

=head1 METHODS

=head2 new

    $os = ksb::OSSupport->new;

    # Manually point to os-release
    $os = ksb::OSSupport->new('/usr/lib/os-release');

Creates a new object. Required for other methods.

=cut

sub new
{
    my ($class, $file) = @_;

    my $self = bless {
    }, $class;

    # $file might be undef
    my @kvListRef = $self->_readOSRelease($file);

    # Result comes in a listref which itself contains 2-elem
    # lists... flatten list so it can be assigned to the hash
    %{$self} = map { @{$_}[0,1] } @kvListRef;

    return $self;
}

=head2 vendorID

    my $vendor = $os->vendorID; # 'gentoo', 'debian', etc.

Returns the vendor ID from the I<os-release> specification.

=cut

sub vendorID
{
    my $self = shift;
    return $self->{ID} // 'unknown';
}

=head2 vendorVersion

    my $vendor = $os->vendorVersion; # 'xenial', '17', etc.

Returns the vendor Version from the I<os-release> specification.
The first available value from C<VERSION_ID> and then
C<VERSION_CODENAME> is used, and 'unknown' is returned if neither
are set.

=cut

sub vendorVersion
{
    my $self = shift;
    return $self->{VERSION_ID} // $self->{VERSION_CODENAME} // 'unknown';
}

=head2 bestDistroMatch

    # Might return 'fedora' if running on Scientific Linux
    my $distro = $os->bestDistroMatch(qw/ubuntu fedora arch debian/);

This uses the ID (and if needed, ID_LIKE) parameter in
/etc/os-release to find the best possible match amongst the
provided distro IDs. The list of distros should be ordered with
most specific distro first.

If no match is found, returns 'linux' (B<not> undef, '', or
similar)

=cut

sub bestDistroMatch
{
    my ($self, @distros) = @_;
    my @ids = $self->vendorID;

    if (my $likeDistros = $self->{ID_LIKE} // '') {
        push @ids, split(' ', $likeDistros);
    }

    foreach my $id (@ids) {
        return $id if first { $id eq $_ } @distros;
    }

    return 'linux';
}

sub _readOSRelease
{
    my ($self, $fileName) = @_;
    my @files = $fileName ? $fileName : qw(/etc/os-release /usr/lib/os-release);
    my ($fh, $error);

    while (!$fh && @files) {
        my $file = shift @files;
        open $fh, '<:encoding(UTF-8)', $file and last;
        $error = $!;
    }

    croak_runtime("Can't open os-release! $error")
        unless $fh;

    # skip comments and blank lines, and whitespace-only lines
    my @lines = grep { ! /^\s*(?:#.*)?\s*$/ }
                map  { chomp; $_ }
                    <$fh>;
    close $fh;

    # 0 allows discarding the delimiter and any quotes
    # Return should be one list per line, hopefully each list has
    # exactly 2 values ([$key, $value]).
    return nested_quotewords('=', 0, @lines);
}

1;
