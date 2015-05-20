package ksb::RecursiveFH;

use strict;
use warnings;
use 5.014;

our $VERSION = '0.10';

use ksb::Util;
use File::Basename; # dirname

# TODO: Replace make_exception with appropriate croak_* function.
sub new
{
    my ($class) = @_;
    my $data = {
        'filehandles' => [],    # Stack of filehandles to read
        'base_path'   => [],    # Base directory path for relative includes
        'current'     => undef, # Current filehandle to read
    };

    return bless($data, $class);
}

# Adds a new filehandle to read config data from.
#
# This should be called in conjunction with pushBasePath to allow for recursive
# includes from different folders to maintain the correct notion of the current
# cwd at each recursion level.
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

# Sets the base directory to use for any future encountered include entries
# that use relative notation, and saves the existing base path (as on a stack).
# Use in conjunction with addFilehandle, and use popFilehandle and popBasePath
# when done with the filehandle.
sub pushBasePath
{
    my $self = shift;
    push @{$self->{base_path}}, shift;
}

# See above
sub popBasePath
{
    my $self = shift;
    return pop @{$self->{base_path}};
}

# Returns the current base path to use for relative include declarations.
sub currentBasePath
{
    my $self = shift;
    my $curBase = $self->popBasePath();

    $self->pushBasePath($curBase);
    return $curBase;
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
            $self->popBasePath();

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
            my $prefix = $self->currentBasePath();

            $filename =~ s/^~\//$ENV{HOME}\//; # Tilde-expand
            $filename = "$prefix/$filename" unless $filename =~ m(^/);

            open ($newFh, '<', $filename) or
                die make_exception('Config',
                    "Unable to open file $filename which was included from line $.");

            $prefix = dirname($filename); # Recalculate base path
            $self->addFilehandle($newFh);
            $self->pushBasePath($prefix);

            redo READLINE;
        }
        else {
            return $line;
        }
    }
}

1;
