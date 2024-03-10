# SPDX-FileCopyrightText: 2023 Michael Pyne <mpyne@kde.org>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::DBus 0.10;

use ksb;

=head1 SYNOPSIS

 my $dbusConnection;

 # exceptions thrown on failure to find DBus path
 eval {
     ksb::DBus::requestPerformanceProfile()->then(sub ($stream) {
       # if we make it here we've sent a DBus request to apply 'performance'
       # power profile as long as $dbusConnection (a L<Mojo::IOLoop::Stream>)
       # remains open.
       $dbusConnection = $stream;
     });
 }

=cut

=head1 DESCRIPTION

This is a pure-Perl implementation of I<only enough of the DBus protocol> to
send a D-Bus message to the power-profiles-daemon to request the 'performance'
profile be applied.

This is currently the only DBus use within kdesrc-build and the previous way we
implemented this required L<Net::DBus> which has an extremely large dependency
tail to cover the entire breadth of what D-Bus can do. But this dependency is
not packaged everywhere (in particular Alpine is missing it) and we don't need
all of D-Bus anyways.

Though it is incredibly minimal it could be refactored later if a need arises
to do more with this.

=cut

use Mojo::IOLoop;
use Mojo::Util qw(b64_encode);
use Mojo::Promise;

=head1 FUNCTIONS

=cut

sub _hexDecode
{
    my $in = shift;

    # Perl specific nuance! The capturing group (..) in the regex below will
    # ensure that the separator is *also* included in the output where the
    # split occured. We need this because this is what we're going to
    # hex-decode.
    my @components = split(/(%[0-9A-F]{1,2})/, $in);
    die "invalid hex escape" if grep { $_ =~ /^%.$/ } @components;
    my @decoded = map { $_ =~ /^%/ ? pack("H2", substr($_, 1, 2)) : $_ }
                    @components;
    my $result = join('', @decoded);
    return $result;
}

=head2 _buildDBusMessageHeader

Builds a message header for the given DBus METHOD_CALL body. No other DBus
messages are currently supported.

Takes the already-built body along with a hash of options to use for directing
the message to its destination on the bus.

Options:

    obj_path => path to object to call at the destination (e.g. /org/freedesktop/DBus)
    bus_dest => destination on the bus (e.g. org.freedesktop.DBus or :1.118)
    iface    => interface name to call (e.g. org.freedesktop.DBus)
    method   => method name to call (e.g. Hello)
    sig      => signature of the method (must match body!) (e.g. 'sss')

=cut

sub _buildDBusMessageHeader($encoded_body, %fields)
{
    my $endianness = 'l';  # little endian
    my $msg_type   = 1;    # METHOD_CALL
    my $flags      = 3;    # NO_REPLY_EXPECTED (1) | NO_AUTO_START (2)
    my $major_ver  = 1;    # BYTE
    my $body_len   = 0;    # UINT32
    state $msg_serial = 1; # UINT32 "must not be zero"
    my @header_fields;     # array of struct{BYTE,VARIANT}

    $body_len = length $encoded_body;

    if ($fields{response} // 0) {
        # Clear the "ignore reply" bit from flags
        $flags &= ~1;
    }

    # A METHOD_CALL must have header fields for at least:
    # * PATH (1, object_path)
    # * MEMBER (3, string), and (over a message bus) should have:
    # * INTERFACE (2, string) field and
    # * DESTINATION (6, string) field. To pass arguments we also need:
    # * SIGNATURE (8, signature) header field describing the
    # arguments in the BODY of the message.
    #
    # Each field is encoded like 0x01 VAR_TAG UINT STRING_DATA 0x00
    # The UINT is 1 byte for SIGNATURE and 4 bytes little endian for other strings
    # The VAR_TAG is 'o' / 's' / 'g' (object_path / string / signature resp.)
    # Since each field is a STRUCT, each field is aligned to 8-byte boundary

    my $build_field = sub($id, $var_tag, $str, $is_last=0) {
        # See perlpacktut for details of this template syntax
        my $template = "C C Z* x!4 V Z*"; # default for UINT32 string len
        $template = "C C Z* C Z*"         # UINT8 string len for sigs
            if $var_tag eq 'g';
        $template .= " x!8"             # the last item gets NO extra padding
            unless $is_last;

        # the '1' is needed as the length of the SIGNATURE that starts of the
        # VARIANT field before the STRING.
        return pack($template, $id, 1, $var_tag, length $str, $str);
    };

    push @header_fields, $build_field->(1, 'o', $fields{obj_path});
    push @header_fields, $build_field->(2, 's', $fields{iface});
    push @header_fields, $build_field->(3, 's', $fields{method});
    push @header_fields, $build_field->(6, 's', $fields{bus_dest});
    push @header_fields, $build_field->(8, 'g', $fields{sig}, 1); # last one

    my $joined_fields = join('', @header_fields);

    # The overall header must be padded to a multiple of 8 bytes
    my $hdr = pack('A1 C C C V V V a* x!8',
        $endianness, $msg_type, $flags, $major_ver, $body_len, $msg_serial++,
        length $joined_fields, $joined_fields
    );
    return $hdr;
}

# Used to decode a path from a DBus environment variable (session or system bus)
sub _getDBusPathFromEnvironment($envPath)
{
    my ($transport, $options) = split(':', $envPath, 2);
    die "Unhandled DBus transport $transport" unless $transport eq 'unix';
    die "Empty DBus bus address"      unless $options;

    my %decoded_options;

    my @test_options = split('=', $options);
    die "Invalid DBus bus path options"
        unless (((scalar @test_options) % 2) == 0);

    # go sequentially to avoid overwriting a value with a later one
    # the dbus docs indicate priority is supposed to go to earlier options
    # if there are duplicates
    while (@test_options) {
        my ($k, $v) = splice @test_options, 0, 2;
        next if exists $decoded_options{$k};
        $v = _hexDecode($v) if index($v, '%') >= 0;
        $decoded_options{$k} = $v;
    }

    die "No path= option in DBus address"
        unless exists $decoded_options{path};

    return $decoded_options{path};
}

sub _getPathToSessionDBus
{
    my $dbus_path = $ENV{DBUS_SESSION_BUS_ADDRESS};
    die "No DBUS_SESSION_BUS_ADDRESS set" unless $dbus_path;

    return _getDBusPathFromEnvironment($dbus_path);
}

sub _getPathToSystemDBus
{
    my $dbus_path = $ENV{DBUS_SYSTEM_BUS_ADDRESS};

    if ($dbus_path) {
        return _getDBusPathFromEnvironment($dbus_path);
    }

    # first listed path is defined in the spec as the only fallback but the second
    # listed path seems common and aligns to ongoing migrate of $XDG_RUNTIME_DIR out
    # of /var.
    for my $candidate (qw(/var/run/dbus/system_bus/socket /run/dbus/system_bus_socket)) {
        return $candidate if -e $candidate;
    }

    die "Can't find system DBus";
}

# Returns a promise that resolves to an Mojo::IOLoop::Stream connected to the
# DBus bus (system or session). No authentication or setup will have been performed.
sub _connectToDBus($dbus_path)
{
    my $promise = Mojo::Promise->new;
    my $id = Mojo::IOLoop->client({
            path => $dbus_path,
        }, sub ($loop, $err, $stream) {
            if($err) {
                $promise->reject($err);
            } else {
                $stream->on(error => sub ($stream, $err) {
                        $promise->reject($err);
                    });
                $stream->on(timeout => sub ($stream) {
                        $promise->reject("Timeout on DBus connection");
                    });
                $promise->resolve($stream);
            }
        });

    return $promise;
}

# Returns a promise that resolves to the value of the next 'read'
# event from the given stream
sub _getDBusResponse($stream)
{
    my $promise = Mojo::Promise->new;
    $stream->once(read => sub ($stream, $bytes) {
            $promise->resolve($stream, $bytes);
        });

    return $promise;
}

# Returns a promise that resolves once the stream's 'drain' event has
# fired.
sub _waitForDrain($stream)
{
    my $promise = Mojo::Promise->new;
    $stream->once(drain => sub ($stream) {
            $promise->resolve($stream);
        });

    return $promise;
}

=head2 requestPerformanceProfile

Connects to the system D-Bus (including protocol authentication as the current
running user) and if that succeeds, sends a C<HoldProfile> request to the
C<net.hadess.PowerProfiles> service to request the B<performance> profile be
enabled.

Returns a L<Mojo::IOLoop::Stream> connected to the system D-Bus. As long as
this stream remains open, the performance profile should remain applied.

This requires the user to be running power-profiles-daemon, but should cause no
issues if this daemon is not running.

See L<https://gitlab.freedesktop.org/hadess/power-profiles-daemon/-/blob/main/src/net.hadess.PowerProfiles.xml>
for more information on the D-Bus interface

=cut

sub requestPerformanceProfile
{
    return _connectToDBus(_getPathToSystemDBus())->then(sub ($stream) {
            # connection open, send authentication EXTERNAL ...

            # Required before auth request sent
            $stream->write("\x00");

            # $< (uid) must be quoted to force string conversion
            my $hexEncodedUid = unpack("H*", "$<");
            $stream->write("AUTH EXTERNAL $hexEncodedUid\r\n");

            return _getDBusResponse($stream);
        })->then(sub ($stream, $bytes) {
            my ($res, $guid) = split(' ', $bytes);

            die "Unexpected response" unless $res eq 'OK';

            # OK GUID recv'd, send BEGIN and first message (Hello)
            $stream->write("BEGIN\r\n");

            # Hello message
            my %fields = (
                obj_path => '/org/freedesktop/DBus',
                bus_dest => 'org.freedesktop.DBus',
                iface    => 'org.freedesktop.DBus',
                method   => 'Hello',
                sig      => '',
                response => 1,
            );

            $stream->write(_buildDBusMessageHeader('', %fields));

            return _getDBusResponse($stream);
        })->then(sub ($stream, $bytes) {
            # check response, should be METHOD_REPLY
            die 'empty response' unless $bytes;

            my ($endian, $msg_type, undef, undef, $body_len) =
                unpack('A1 C C C V', $bytes);
            die "unhandled endianness $endian" unless $endian eq 'l';

            # 2 == METHOD_RETURN. 3 would be an ERROR.
            die "Message type $msg_type incorrect" unless $msg_type == 2;

            # Three params are all strings, 'performance', reason,
            # and program that placed the hold
            # Each string is serialized by a 4-byte length
            # (exclusive of required terminating null) then the
            # string

            my @args = ('performance', 'Building software', 'kdesrc-build');
            my $body = pack("V Z* x!4 V Z* x!4 V Z*",
                map { (length $_, $_) } @args);

            my %fields = (
                obj_path => '/net/hadess/PowerProfiles',
                bus_dest => 'net.hadess.PowerProfiles',
                iface    => 'net.hadess.PowerProfiles',
                method   => 'HoldProfile',
                sig      => 'sss',
            );

            my $hdr = _buildDBusMessageHeader($body, %fields);
            $stream->write($hdr . $body);

            return _waitForDrain($stream);
        })->catch(sub ($err) {
            say STDERR "Caught error $err!";
        });
}

1;
