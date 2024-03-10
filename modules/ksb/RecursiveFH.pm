# SPDX-FileCopyrightText: 2012, 2014 Michael Pyne <mpyne@kde.org>
# SPDX-FileCopyrightText: 2016 David Faure <faure@kde.org>
# SPDX-FileCopyrightText: 2024 Andrew Shark <ashark@linuxcomp.ru>
#
# SPDX-License-Identifier: GPL-2.0-or-later

package ksb::RecursiveFH;

use ksb;
use ksb::Debug;

our $VERSION = '0.10';

use ksb::BuildException;
use ksb::Util;
use File::Basename; # dirname

# TODO: Replace make_exception with appropriate croak_* function.
sub new
{
    my ($class, $rcfile, $ctx) = @_;
    my $data = {
        'filehandles' => [],    # Stack of filehandles to read
        'filenames'   => [],    # Corresponding tack of filenames (full paths)
        'base_path'   => [],    # Base directory path for relative includes
        'current'     => undef, # Current filehandle to read
        'current_fn'  => undef, # Current filename
        'ctx'         => $ctx,
    };

    my $self = bless($data, $class);
    $self->pushBasePath(dirname($rcfile)); # rcfile should already be absolute
    return $self;
}

# Adds a new filehandle to read config data from.
#
# This should be called in conjunction with pushBasePath to allow for recursive
# includes from different folders to maintain the correct notion of the current
# cwd at each recursion level.
sub addFile
{
    my ($self, $fh, $fn) = @_;
    push @{$self->{filehandles}}, $fh;
    push @{$self->{filenames}}, $fn;
    $self->setCurrentFile($fh, $fn);
}

sub popFilehandle
{
    my $self = shift;
    pop @{$self->{filehandles}};
    pop @{$self->{filenames}};
    my $newFh = scalar @{$self->{filehandles}} ? ${$self->{filehandles}}[-1]
                                               : undef;
    my $newFilename = scalar @{$self->{filenames}} ? ${$self->{filenames}}[-1]
                                               : undef;
    $self->setCurrentFile($newFh, $newFilename);
}

sub currentFilehandle
{
    my $self = shift;
    return $self->{current};
}

sub currentFilename
{
    my $self = shift;
    return $self->{current_fn};
}

sub setCurrentFile
{
    my ($self, $fh, $fn) = @_;
    $self->{current} = $fh;
    $self->{current_fn} = $fn;
}

# Sets the base directory to use for any future encountered include entries
# that use relative notation, and saves the existing base path (as on a stack).
# Use in conjunction with addFile, and use popFilehandle and popBasePath
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
            $self->popFilehandle();
            $self->popBasePath();

            my $fh = $self->currentFilehandle();

            return undef if !defined($fh);

            redo READLINE;
        }
        elsif ($line =~ /^\s*include\s+\S/) {
            # Include found, extract file name and open file.
            chomp $line;
            my ($filename) = ($line =~ /^\s*include\s+(.+?)\s*$/);

            if (!$filename) {
                die make_exception('Config', "Unable to handle file include '$line' from $self->{current_fn}:$.");
            }

            # Existing configurations (before 2023 December) may have pointed to the build-include files located in root of project
            # Warn those users to update the path, and automatically map to new location
            # TODO remove this check after May 2024
            if ($filename =~ /-build-include$/) {
                $filename =~ s/-build-include$/.ksb/;  # replace the ending "-build-include" with ".ksb"
                $filename =~ s,.*/([^/]+)$,\${module-definitions-dir}/$1,;  # extract the file name (after the last /), and append it to "${module-definitions-dir}/" string
                warning (<<~EOM);
                y[Warning:] The include line defined in $self->{current_fn}:$. uses an old path to build-include file.
                The module-definitions files are now located in repo-metadata.
                The configuration file is intended to only have this include line (please manually edit your config):
                    include \${module-definitions-dir}/kf6-qt6.ksb
                Alternatively, you can regenerate the config with --generate-config option.
                Mapping this line to "include $filename"
                EOM
            }
            if ($filename =~ /\/data\/build-include/) {
                $filename =~ s,.*/data/build-include/([^/]+)$,\${module-definitions-dir}/$1,;  # extract the file name (after the last /), and append it to "${module-definitions-dir}/" string
                warning (<<~EOM);
                y[Warning:] The include line defined in $self->{current_fn}:$. uses an old path with data/build-include.
                The module-definitions files are now located in repo-metadata.
                The configuration file is intended to only have this include line (please manually edit your config):
                    include \${module-definitions-dir}/kf6-qt6.ksb
                Alternatively, you can regenerate the config with --generate-config option.
                Mapping this line to "include $filename"
                EOM
            }

            my $optionRE = qr/\$\{([a-zA-Z0-9-_]+)\}/;  # Example of matched string is "${option-name}" or "${_option-name}".
            my $ctx = $self->{ctx};

            # Replace reference to global option with their value.
            my ($sub_var_name) = ($filename =~ $optionRE);
            while ($sub_var_name)
            {
                my $sub_var_value = $ctx->getOption($sub_var_name) || "";
                if(!$ctx->hasOption($sub_var_name)) {
                    warning (" *\n * WARNING: y[$sub_var_name] used in $self->{current_fn}:$. is not set in global context.\n *");
                }

                debug ("Substituting \${$sub_var_name} with $sub_var_value");

                $filename =~ s/\$\{$sub_var_name\}/$sub_var_value/g;

                # Replace other references as well.
                ($sub_var_name) = ($filename =~ $optionRE);
            }

            my $newFh;
            my $prefix = $self->currentBasePath();
            $filename =~ s/^~\//$ENV{HOME}\//; # Tilde-expand
            $filename = "$prefix/$filename" unless $filename =~ m(^/);

            open ($newFh, '<', $filename) or
                die make_exception('Config', "Unable to open file '$filename' which was included from $self->{current_fn}:$.");

            $prefix = dirname($filename); # Recalculate base path
            $self->addFile($newFh, $filename);
            $self->pushBasePath($prefix);

            redo READLINE;
        }
        else {
            return $line;
        }
    }
}

1;
