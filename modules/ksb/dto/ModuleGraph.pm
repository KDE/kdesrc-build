package ksb::dto::ModuleGraph;

use strict;
use warnings;
use 5.014;


#
# dto::ModuleGraph
#
# This module provides utilities to convert from the internal representation
# of a module/dependency graph to its wire format equivalent, and vice versa.
# Using DTOs is a well known good practice to ensure API output reflects a
# semantically meaningful view, without cluttering it with internal,
# implementation specific notions of what 'model' is actually represented.
#

#
# Note: traps for the unway: Mojo::JSON only really kicks in on reference types
# What that means in practice is that you *have* to construct refs to get type
# based encoding to work:
#
#  - In order to get correct `true` or `false` output for boolean keys you
#    should use a ref to a scalar
#  - In order to get correct list output for arrays you should use a ref to an
#    array
#
# Note: while JSON has the notion of null values the same thing can also be
# expressed by the fact that fields are optional. That is better; so instead
# of assigning null/undef to a key, avoid setting the field at all if possible.
#

sub dependencyGraphToDto
{
    my $graph = shift;
    my $dto = {};
    for my $key (keys %{$graph})
    {
        my @allDeps = keys %{$graph->{$key}->{allDeps}->{items}};
        my @deps = keys %{$graph->{$key}->{deps}};
        my @votes = keys %{$graph->{$key}->{votes}};
        my $branch = $graph->{$key}->{branch} // '';
        my $isBuilt = $graph->{$key}->{build} ? 1: 0;
        my $hasModule = defined($graph->{$key}->{module}) ? 1 : 0;

        $dto->{$key} = {
            allDeps => \@allDeps,
            deps => \@deps,
            votes => \@votes,
            path => $graph->{$key}->{path}
        };

        $dto->{$key}->{branch} = "$branch" unless $branch eq '';
        $dto->{$key}->{build} = \$isBuilt;
        $dto->{$key}->{module} = \$hasModule;
    }

    return $dto;
}

sub dependencyInfoToDto
{
    my $info = shift;

    my $cycles = $info->{cycles} // 0;
    my $trivialCycles = $info->{trivialCycles} // 0;
    my $branchErrors = $info->{branchErrors} // 0;
    my $syntaxErrors = $info->{syntaxErrors} // 0;
    my $pathErrors = $info->{pathErrors} // 0;
    my $errors = $cycles + $branchErrors + $syntaxErrors + $pathErrors;

    my $dto = {
        errors => {
            cycles => $cycles,
            trivialCycles => $trivialCycles,
            branches => $branchErrors,
            paths => $pathErrors,
            errors => $errors
        }
    };

    my $graph = $info->{graph};
    return $dto unless defined($graph);

    $dto->{data} = dependencyGraphToDto($graph);
    return $dto;
}

1;
