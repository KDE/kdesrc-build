package web::BackendServer;

# Make this subclass a Mojolicious app
use Mojo::Base 'Mojolicious';
use Mojo::Util qw(trim);

use ksb::Application;

use Cwd;

# This is written in a kind of domain-specific language for Mojolicious for
# now, to setup a web server backend for clients / frontends to communicate
# with.
# See https://mojolicious.org/perldoc/Mojolicious/Guides/Tutorial

has 'options';
has 'selectors';

sub new
{
    my ($class, @opts) = @_;
    return $class->SUPER::new(options => [@opts], ksbhome => getcwd());
}

# Adds a helper method to each HTTP context object to return the
# ksb::Application class in use
sub make_new_ksb
{
    my $c = shift;

    # ksb::Application startup uses current dir to find right rc-file
    # by default.
    chdir($c->app->{ksbhome});
    my $app = ksb::Application->new->setHeadless;

    my @selectors = $app->establishContext(@{$c->app->{options}});
    $c->app->selectors([@selectors]);
    $c->app->log->info("Selectors are ", join(', ', @selectors));

    return $app;
}

# Package-shared variables for helpers and closures
my $LAST_RESULT;
my $BUILD_PROMISE;
my $IN_PROGRESS;
my $KSB_APP;

sub startup {
    my $self = shift;

    # Force use of 'modules/web' as the home directory, would normally be
    # 'modules' alone
    $self->home($self->home->child('web'));

    # Fixup templates and public base directories
    $self->static->paths->[0]   = $self->home->child('public');
    $self->renderer->paths->[0] = $self->home->child('templates');

    $self->helper(ksb => sub {
        my ($c, $new_ksb) = @_;

        $KSB_APP //= make_new_ksb($c);
        $KSB_APP = $new_ksb if $new_ksb;

        return $KSB_APP;
    });

    $self->helper(in_build => sub { $IN_PROGRESS });
    $self->helper(context  => sub { shift->ksb->context() });

    my $r = $self->routes;
    $self->_generateRoutes;

    return;
}

sub _generateRoutes {
    my $self = shift;
    my $r = $self->routes;

    $r->get('/' => 'index');

    $r->post('/reset' => sub {
        my $c = shift;

        if ($c->in_build || !defined $LAST_RESULT) {
            $c->res->code(400);
            return $c->render;
        }

        my $old_result = $LAST_RESULT;
        $c->ksb(make_new_ksb($c));
        undef $LAST_RESULT;

        $c->render(json => { last_result => $old_result });
    });

    $r->get('/context/options' => sub {
        my $c = shift;
        $c->render(json => $c->ksb->context()->{options});
    });

    $r->get('/context/options/:option' => sub {
        my $c = shift;
        my $ctx = $c->ksb->context();

        my $opt = $c->param('option') or do {
            $c->res->code(400);
            return $c->render;
        };

        if (defined $ctx->{options}->{$opt}) {
            $c->render(json => { $opt => $ctx->{options}->{$opt} });
        }
        else {
            $c->res->code(404);
            $c->reply->not_found;
        }
    });

    $r->get('/modules' => sub {
        my $c = shift;
        $c->render(json => $c->ksb->context()->moduleList());
    } => 'module_lookup');

    $r->get('/known_modules' => sub {
        my $c = shift;
        my $resolver = $c->ksb->{module_resolver};
        my @setsAndModules = @{$resolver->{inputModulesAndOptions}};
        my @output = map {
            $_->isa('ksb::ModuleSet')
                ? [ $_->name(), $_->moduleNamesToFind() ]
                : $_->name() # should be a ksb::Module
        } @setsAndModules;

        $c->render(json => \@output);
    });

    $r->post('/modules' => sub {
        my $c = shift;
        my $selectorList = $c->req->json;
        my $build_all = $c->req->headers->header('X-BuildAllModules');

        # Remove empty selectors
        my @modules = grep { !!$_ } map { trim($_ // '') } @{$selectorList};

        # If not building all then ensure there's at least one module to build
        if ($c->in_build || !$selectorList || (!@modules && !$build_all) || (@modules && $build_all)) {
            $c->app->log->error("Something was wrong with modules to assign to build");
            return $c->render(text => "Invalid request sent", status => 400);
        }

        eval {
            @modules = $c->ksb->modulesFromSelectors(@modules);
            $c->ksb->setModulesToProcess(@modules);
        };

        if ($@) {
            return $c->render(text => $@->{message}, status => 400);
        }

        my $numSels = @modules; # count

        $c->render(json => ["$numSels handled"]);
    }, 'post_modules');

    $r->get('/module/:modname' => sub {
        my $c = shift;
        my $name = $c->stash('modname');

        my $module = $c->ksb->context()->lookupModule($name);
        if (!$module) {
            $c->render(template => 'does_not_exist');
            return;
        }

        my $opts = {
            options => $module->{options},
            persistent => $c->ksb->context()->{persistent_options}->{$name},
        };
        $c->render(json => $opts);
    });

    $r->get('/module/:modname/logs/error' => sub {
        my $c = shift;
        my $name = $c->stash('modname');
        $c->render(text => "TODO: Error logs for $name");
    });

    $r->get('/config' => sub {
        my $c = shift;
        $c->render(text => $c->ksb->context()->rcFile());
    });

    $r->post('/config' => sub {
        # TODO If new filename can be loaded, load it and reset application object
        die "Unimplemented";
    });

    $r->get('/build-metadata' => sub {
        die "Unimplemented";
    });

    $r->websocket('/events' => sub {
        my $c = shift;

        $c->inactivity_timeout(0);

        my $ctx = $c->ksb->context();
        my $monitor = $ctx->statusMonitor();

        # Send prior events the receiver wouldn't have received yet
        my @curEvents = $monitor->events();
        $c->send({json => \@curEvents});

        # Hook up an event handler to send future events as they're generated
        $monitor->on(newEvent => sub {
            my ($monitor, $resultRef) = @_;
            $c->on(drain => sub { $c->finish })
                if ($resultRef->{event} eq 'build_done');
            $c->send({json => [ $resultRef ]});
        });
    });

    $r->get('/event_viewer' => sub {
        my $c = shift;
        $c->render(template => 'event_viewer');
    });

    $r->get('/building' => sub {
        my $c = shift;
        $c->render(text => $c->in_build ? 'True' : 'False');
    });

    $r->post('/build' => sub {
        my $c = shift;
        if ($c->in_build) {
            $c->res->code(400);
            $c->render(text => 'Build already in progress, cancel it first.');
            return;
        }

        $c->app->log->debug('Starting build');

        $IN_PROGRESS = 1;

        $BUILD_PROMISE = $c->ksb->startHeadlessBuild->finally(sub {
            my ($result) = @_;
            $c->app->log->debug("Build done");
            $IN_PROGRESS = 0;
            return $LAST_RESULT = $result;
        });

        $c->render(text => $c->url_for('event_viewer')->to_abs->to_string);
    });
}

1;
