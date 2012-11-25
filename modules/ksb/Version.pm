package ksb::Version;

# Pretty much just records the program-wide version number...

use strict;
use warnings;
use v5.10;

our $VERSION = '1.16-pre1';

our $SCRIPT_VERSION = $VERSION;

use Exporter qw(import);
our @EXPORT = qw(scriptVersion);

sub scriptVersion()
{
    return $SCRIPT_VERSION;
}

1;
