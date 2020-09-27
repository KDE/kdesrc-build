package ksb::UserInterface::DependencyGraph;

use utf8; # Source code is utf8-encoded

use warnings;
use v5.22;

# our output to STDOUT should match locale (esp UTF-8 locale, which induces
# warnings for UTF-8 output unless we specifically opt-in)
use open OUT => ':locale';

sub _descendModuleGraph
{
    my ($moduleGraph, $callback, $nodeInfo, $context) = @_;

    my $depth = $nodeInfo->{depth};
    my $index = $nodeInfo->{idx};
    my $count = $nodeInfo->{count};
    my $currentItem = $nodeInfo->{currentItem};
    my $currentBranch = $nodeInfo->{currentBranch};
    my $parentItem = $nodeInfo->{parentItem};
    my $parentBranch = $nodeInfo->{parentBranch};

    my $subGraph = $moduleGraph->{$currentItem};
    &$callback($nodeInfo, $subGraph->{module}, $context);

    ++$depth;

    my @items = @{$subGraph->{deps}};

    my $itemCount = scalar(@items);
    my $itemIndex = 1;

    for my $item (@items)
    {
        $subGraph = $moduleGraph->{$item};
        my $branch = $subGraph->{branch} // '';
        my $itemInfo = {
            build => $subGraph->{build},
            depth => $depth,
            idx => $itemIndex,
            count => $itemCount,
            currentItem => $item,
            currentBranch => $branch,
            parentItem => $currentItem,
            parentBranch => $currentBranch
        };
        _descendModuleGraph($moduleGraph, $callback, $itemInfo, $context);
        ++$itemIndex;
    }
}

sub _walkModuleDependencyTrees
{
    my $moduleGraph = shift;
    my $callback = shift;
    my $context = shift;
    my @modules = @_;
    my $itemCount = scalar(@modules);
    my $itemIndex = 1;

    for my $item (@modules) {
        my $subGraph = $moduleGraph->{$item};
        my $branch = $subGraph->{branch} // '';
        my $info = {
            build => $subGraph->{build},
            depth => 0,
            idx => $itemIndex,
            count => $itemCount,
            currentItem => $item,
            currentBranch => $branch,
            parentItem => '',
            parentBranch => ''
        };
        _descendModuleGraph($moduleGraph, $callback, $info, $context);
        ++$itemIndex;
    }
}


sub _treeOutputConnectors
{
    my ($depth, $index, $count) = @_;
    my $blankPadding = (' ' x 4);

    my $unicode = ($ENV{LC_ALL} // 'C') =~ /UTF-?8$/;

    if ($unicode) {
        return (' ── ', $blankPadding) if ($depth == 0);
        return ('└── ', $blankPadding) if ($index == $count);
        return ('├── ', '│   ');
    } else {
        return (' -- ', $blankPadding) if ($depth == 0);
        return ('\-- ', $blankPadding) if ($index == $count);
        return ('+-- ', '|   ');
    }
}

sub _yieldModuleDependencyTreeEntry
{
    my ($nodeInfo, $module, $context) = @_;

    my $depth = $nodeInfo->{depth};
    my $index = $nodeInfo->{idx};
    my $count = $nodeInfo->{count};
    my $build = $nodeInfo->{build};
    my $currentItem = $nodeInfo->{currentItem};
    my $currentBranch = $nodeInfo->{currentBranch};
    my $parentItem = $nodeInfo->{parentItem};
    my $parentBranch = $nodeInfo->{parentBranch};

    my $buildStatus = $build ? 'built' : 'not built';
    my $statusInfo = $currentBranch ? "($buildStatus: $currentBranch)" : "($buildStatus)";

    my $connectorStack = $context->{stack};
    my $prefix = pop(@$connectorStack);

    while($context->{depth} > $depth) {
        $prefix = pop(@$connectorStack);
        --($context->{depth});
    }

    push(@$connectorStack, $prefix);

    my ($connector, $padding) = _treeOutputConnectors($depth, $index, $count);

    push(@$connectorStack, $prefix . $padding);
    $context->{depth} = $depth + 1;

    my $line = $prefix . $connector . $currentItem . ' ' . $statusInfo;
    $context->{report}($line);
}

sub printTrees
{
    my $tree = shift;
    my @modules = @_;

    my $depTreeCtx = {
        stack => [''],
        depth => 0,
        report => sub {
            say $_[0];
        }
    };

    _walkModuleDependencyTrees(
        $tree,
        \&_yieldModuleDependencyTreeEntry,
        $depTreeCtx,
        @modules
    );

    return 0;
}

1;
