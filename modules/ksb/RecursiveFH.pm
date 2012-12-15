package ksb::RecursiveFH;

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use ksb::Util;

# TODO: Replace make_exception with appropriate croak_* function.
sub new
{
    my ($class) = @_;
    my $data = {
        'filehandles' => [],    # Stack of filehandles to read
        'current'     => undef, # Current filehandle to read
    };

    return bless($data, $class);
}

sub addFilehandle
{
    my ($self, $fh) = @_;
    push @{$self->{filehandles}}, $fh;
    $self->setCurrentFilehandle($fh);
}

sub popFilehandle
{
    my $self = shift;
    my $result = pop @{$self->{filehandles}};
    my $newFh = scalar @{$self->{filehandles}} ? ${$self->{filehandles}}[-1]
                                               : undef;
    $self->setCurrentFilehandle($newFh);
    return $result;
}

sub currentFilehandle
{
    my $self = shift;
    return $self->{current};
}

sub setCurrentFilehandle
{
    my $self = shift;
    $self->{current} = shift;
}

# Reads the next line of input and returns it.
# If a line of the form "include foo" is read, this function automatically
# opens the given file and starts reading from it instead. The original
# file is not read again until the entire included file has been read. This
# works recursively as necessary.
#
# No further modification is performed to returned lines.
#
# undef is returned on end-of-file (but only of the initial filehandle, not
# included files from there)
sub readLine
{
    my $self = shift;

    # Starts a loop so we can use evil things like "redo"
    READLINE: {
        my $line;
        my $fh = $self->currentFilehandle();

        # Sanity check since different methods might try to read same file reader
        return undef unless defined $fh;

        if (eof($fh) || !defined($line = <$fh>)) {
            my $oldFh = $self->popFilehandle();
            close $oldFh;

            my $fh = $self->currentFilehandle();

            return undef if !defined($fh);

            redo READLINE;
        }
        elsif ($line =~ /^\s*include\s+\S/) {
            # Include found, extract file name and open file.
            chomp $line;
            my ($filename) = ($line =~ /^\s*include\s+(.+)$/);

            if (!$filename) {
                die make_exception('Config',
                    "Unable to handle file include on line $., '$line'");
            }

            my $newFh;
            $filename =~ s/^~\//$ENV{HOME}\//; # Tilde-expand

            open ($newFh, '<', $filename) or
                die make_exception('Config',
                    "Unable to open file $filename which was included from line $.");

            $self->addFilehandle($newFh);

            redo READLINE;
        }
        else {
            return $line;
        }
    }
}

1;
