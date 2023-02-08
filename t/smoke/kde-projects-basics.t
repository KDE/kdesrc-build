# Verify that test kde-project data still results in workable build.

use ksb;
use Test::More;

use ksb::Application;
use ksb::Module;

# The file has a module-set that only refers to juk but should expand to
# kcalc juk in that order
my @args = qw(--pretend --rc-file t/data/kde-projects/kdesrc-buildrc-with-deps);

{
    my $app = ksb::Application->new(@args);
    my @moduleList = @{$app->{modules}};

    is (scalar @moduleList, 2, 'Right number of modules (include-dependencies)');
    is ($moduleList[0]->name(), 'kcalc', 'Right order: kcalc before juk');
    is ($moduleList[1]->name(), 'juk', 'Right order: juk after kcalc');
    is ($moduleList[0]->getOption('tag'), 'tag-setmod2', 'options block works for kde-projects module-set');
}

done_testing();
