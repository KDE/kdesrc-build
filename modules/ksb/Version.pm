package ksb::Version;

# Pretty much just records the program-wide version number...

use strict;
use warnings;
use 5.014;

# It is expected that future git tags will be in the form 'YY.MM' and will
# be time-based instead of event-based as with previous releases.
our $VERSION = '15.05';

our $SCRIPT_VERSION = $VERSION;

use Exporter qw(import);
our @EXPORT = qw(scriptVersion);

sub scriptVersion()
{
    return $SCRIPT_VERSION;
}

1;
