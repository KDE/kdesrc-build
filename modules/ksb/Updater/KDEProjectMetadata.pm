package ksb::Updater::KDEProjectMetadata;

# Updater used only to specifically update the "kde-build-metadata" module
# used for storing dependency information, among other things.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.20';

use ksb::Util;
use ksb::Debug;
use ksb::Updater::KDEProject;

our @ISA = qw(ksb::Updater::KDEProject);

my $haveJson = eval { require JSON; JSON->import(); 1; };

sub name
{
    return 'metadata';
}

# Returns a list of the full kde-project paths for each module to ignore.
sub ignoredModules
{
    my $self = assert_isa(shift, 'ksb::Updater::KDEProjectMetadata');
    my $path = $self->module()->fullpath('source') . "/build-script-ignore";

    # Now that we in theory have up-to-date source code, read in the
    # ignore file and propagate that information to our context object.

    my $fh = pretend_open($path) or
        croak_internal("Unable to read ignore data from $path: $!");

    my $ctx = $self->module()->buildContext();
    my @ignoreModules = map  { chomp $_; $_ } # 3 Remove newlines
                        grep { !/^\s*$/ }     # 2 Filter empty lines
                        map  { s/#.*$//; $_ } # 1 Remove comments
                        (<$fh>);

    return @ignoreModules;
}

# If JSON support is present, and the metadata has already been downloaded
# (e.g. with ->updateInternal), returns a hashref to the logical module group
# data contained within the kde-build-metadata, decoded from its JSON format.
# See http://community.kde.org/Infrastructure/Project_Metadata
sub logicalModuleGroups
{
    my $self = shift;
    my $path = $self->module()->fullpath('source') . "/logical-module-structure";

    croak_runtime("Logical module groups require the Perl JSON module")
        unless $haveJson;

    my $fh = pretend_open($path) or
        croak_internal("Unable to read logical module structure: $!");

    # The 'local $/' disables line-by-line reading; slurps the whole file
    my $json_hashref = do { local $/; decode_json(<$fh>); };
    close $fh;

    return $json_hashref;
}

1;
