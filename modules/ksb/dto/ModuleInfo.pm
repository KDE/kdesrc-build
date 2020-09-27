package ksb::dto::ModuleInfo;

use strict;
use warnings;
use v5.22;

use ksb::Module;


#
# dto::ModuleInfo
#
# This module provides utilities to convert from the internal representation
# of a module object to its wire format equivalent, and vice versa.
# Using DTOs is a well known good practice to ensure API output reflects a
# semantically meaningful view, without cluttering it with internal,
# implementation specific notions of what 'model' is actually represented.
#

sub selectedModuleToDto
{
    my $graph = shift;
    # TODO
    # Perl WTF: does *not* work: assert_isa(shift, 'ksb::Module');
    # but say (ref $module) outputs ksb::Module
    my $module = shift;

    my $name = $module->name();
    my $branch = $graph->{$name}->{branch} // '';
    my $isBuilt = $graph->{$name}->{build} ? 1: 0;
    my $dto = {
        name => $name,
        path => $graph->{$name}->{path}
    };

    $dto->{branch} = "$branch" unless $branch eq '';
    $dto->{build} = \$isBuilt;
    return $dto;
}

sub selectedModulesToDtos
{
    my ($graph, $modules) = @_;
    my @dtos = map { selectedModuleToDto($graph, $_); } (@$modules);
    return @dtos;
}

1;
