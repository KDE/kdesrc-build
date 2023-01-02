package ksb::OSSupport 0.10;

use ksb;

use ksb::BuildException qw(croak_runtime);

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

B<NOTE> This module is supposed to be loadable even under minimal Perl
environments as fielded in "minimal Docker container" forms of popular distros.

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

Returns the vendor ID from the I<os-release> specification, or
'unknown' if /etc/os-release could not be read.

N.B., this is B<not the same as the operating system>!  To
detect the OS use Perl's own L<$^O|perlvar/$OSNAME> variable,
documented in L<perlvar>.

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

=head2 isDebianBased

Returns boolean. 1 (true) if this is a Linux distribution based on Debian, 0 (false) otherwise.

=cut

sub isDebianBased
{
    my $self = shift;

    return 1 if $self->{ID} eq 'debian';

    if (my $likeDistros = $self->{ID_LIKE} // '') {
        my @likeDistrosAsArray = split(' ', $likeDistros);
        if ( grep( /^debian$/, @likeDistrosAsArray ) ) {
            return 1
        }
    }

    return 0;
}

=head2 detectTotalMemory

    my $mem_total_KiB = $os->detectTotalMemory;

Returns the amount of installed memory, in kilobytes.  Linux and FreeBSD are
supported.

Throws a runtime exception if unable to autodetect memory capacity.

=cut

sub detectTotalMemory($self)
{
    my $mem_total;
    if ($^O eq 'freebsd') {
        chomp($mem_total = `sysctl -n hw.physmem`);
        # FreeBSD reports memory in Bytes, not KiB. Convert to KiB so logic
        # below still works sprintf is used since there's no Perl round
        # function
        $mem_total = int sprintf("%.0f", $mem_total / 1024.0);
    } elsif ($^O eq 'linux' or -e '/proc/meminfo') {
        # linux or potentially linux-compatible
        my $total_mem_line = first { /MemTotal/ } (`cat /proc/meminfo`);

        if ($total_mem_line && $? == 0) {
            ($mem_total) = ($total_mem_line =~ /^MemTotal:\s*([0-9]+) /); # Value in KiB
            $mem_total = int $mem_total;
        }
    } else {
        croak_runtime("Unable to detect total memory. OS: $^O, detected vendor: ". $self->vendorID);
    }

    return $mem_total;
}

=head2 bestDistroMatch

    # Might return 'fedora' if running on Scientific Linux
    my $distro = $os->bestDistroMatch(qw/ubuntu fedora arch debian/);

This uses the ID (and if needed, ID_LIKE) parameter in
/etc/os-release to find the best possible match amongst the
provided distro IDs. The list of distros should be ordered with
most specific distro first.

If no match is found, returns a generic os string (B<not> undef, '', or
similar): 'linux' or 'freebsd' as the case may be.

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

    # Special cases that aren't linux
    return $ids[0] if first { $ids[0] eq $_ } qw/freebsd/;
    # .. everything else is generic linux
    return 'linux';
}

sub _readOSRelease
{
    my ($self, $fileName) = @_;
    my @files = $fileName ? $fileName : qw(/etc/os-release /usr/lib/os-release /usr/local/etc/os-release);
    my ($fh, $error);

    while (!$fh && @files) {
        my $file = shift @files;

        # Can't use PerlIO UTF-8 encoding on minimal distros, which this module
        # must be loadable from
        open ($fh, '<', $file) and last;
        $error = $!;
        $fh = undef;
    }

    return unless $fh;

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
