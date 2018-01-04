#!/usr/bin/perl
use 5.10.1;
use strict;
use warnings;
use lib qw(/app /app/local/lib/perl5);
use autodie qw(:all);

use Bugzilla::Install::Localconfig qw(ENV_PREFIX);
use Bugzilla::Install::Util qw(install_string);
use Bugzilla::Test::Util qw(create_user);

use DBI;
use Data::Dumper;
use English qw(-no_match_vars $EUID);
use File::Copy::Recursive qw(dircopy);
use Getopt::Long qw(:config gnu_getopt);
use IO::Async::Loop;
use IO::Async::Process;
use IO::Async::Signal;
use IO::Async::Timer::Periodic;
use LWP::Simple qw(get);
use POSIX qw(WEXITSTATUS setsid);
use Sys::Hostname;
use User::pwent;

BEGIN {
    STDOUT->autoflush(1);
    STDERR->autoflush(1);
}

use constant CI => $ENV{CI};

my $cmd  = shift @ARGV;
my $opts = __PACKAGE__->can("opt_$cmd") // sub { @ARGV };
my $func = __PACKAGE__->can("cmd_$cmd") // sub {
    check_data_dir();
    wait_for_db();
    run(@_);
};

fix_path();
check_user();
check_env(
    'LOCALCONFIG_ENV',
    map { ENV_PREFIX . $_ }
        qw(
            db_host
            db_name
            db_user
            db_pass
            memcached_namespace
            memcached_servers
            urlbase
        )
);

if ( $ENV{ENV_PREFIX . "urlbase"} eq 'AUTOMATIC' ) {
    $ENV{ENV_PREFIX . "urlbase"} = sprintf 'http://%s:%d/%s', hostname(), $ENV{PORT}, $ENV{BZ_QA_LEGACY_MODE} ? 'bmo/' : '';
    $ENV{BZ_BASE_URL} = sprintf 'http://%s:%d', hostname(), $ENV{PORT};
}

$func->($opts->());

sub cmd_demo {
    unless (-f '/app/data/params') {
        cmd_load_test_data();
        check_env(qw(
            PHABRICATOR_BOT_LOGIN
            PHABRICATOR_BOT_PASSWORD
            PHABRICATOR_BOT_API_KEY
            CONDUIT_USER_LOGIN
            CONDUIT_USER_PASSWORD
            CONDUIT_USER_API_KEY
        ));
        run( 'perl', 'scripts/generate_conduit_data.pl' );
    }
    cmd_httpd();
}

sub cmd_httpd  {
    check_data_dir();
    wait_for_db();
    check_httpd_env();
    my @httpd_args = (
        '-DFOREGROUND',
        '-f' => '/app/httpd/httpd.conf',
    );

    # If we're behind a proxy and the urlbase says https, we must be using https.
    # * basically means "I trust the load balancer" anyway.
    if ($ENV{ENV_PREFIX . "inbound_proxies"} eq '*' && $ENV{ENV_PREFIX . "urlbase"} =~ /^https/) {
        unshift @httpd_args, '-DHTTPS';
    }
    run( '/usr/sbin/httpd', @httpd_args );
}

sub cmd_load_test_data {
    wait_for_db();

    die 'BZ_QA_ANSWERS_FILE is not set' unless $ENV{BZ_QA_ANSWERS_FILE};
    run( 'perl', 'checksetup.pl', '--no-template', $ENV{BZ_QA_ANSWERS_FILE} );

    if ($ENV{BZ_QA_LEGACY_MODE}) {
        run( 'perl', 'scripts/generate_bmo_data.pl',
            '--user-pref', 'ui_experiments=off' );
        chdir '/app/qa/config';
        say 'chdir(/app/qa/config)';
        run( 'perl', 'generate_test_data.pl' );
    }
    else {
        run( 'perl', 'scripts/generate_bmo_data.pl', '--param' => 'use_mailer_queue=0' );
    }
}

sub cmd_test_heartbeat {
    my ($url) = @_;
    die "test_heartbeat requires a url!\n" unless $url;

    wait_for_httpd($url);
    my $heartbeat = get("$url/__heartbeat__");
    if ($heartbeat && $heartbeat =~ /Bugzilla OK/) {
        exit 0;
    }
    else {
        exit 1;
    }
}

sub cmd_test_webservices {

    my $conf = require $ENV{BZ_QA_CONF_FILE};

    check_data_dir();
    wait_for_db();

    my @httpd_cmd = ( '/usr/sbin/httpd', '-DFOREGROUND', '-f', '/app/httpd/httpd.conf' );
    if ($ENV{BZ_QA_LEGACY_MODE}) {
        copy_qa_extension();
        push @httpd_cmd, '-DHTTPD_IN_SUBDIR';
    }

    prove_with_httpd(
        httpd_url => $conf->{browser_url},
        httpd_cmd => \@httpd_cmd,
        prove_cmd => [
            'prove', '-qf', '-I/app',
            '-I/app/local/lib/perl5',
            sub { glob 'webservice_*.t' },
        ],
        prove_dir => '/app/qa/t',
    );
}

sub cmd_test_selenium {
    my $conf = require $ENV{BZ_QA_CONF_FILE};

    check_data_dir();
    wait_for_db();
    my @httpd_cmd = ( '/usr/sbin/httpd', '-DFOREGROUND', '-f', '/app/httpd/httpd.conf' );
    if ($ENV{BZ_QA_LEGACY_MODE}) {
        copy_qa_extension();
        push @httpd_cmd, '-DHTTPD_IN_SUBDIR';
    }

    prove_with_httpd(
        httpd_url => $conf->{browser_url},
        httpd_cmd => \@httpd_cmd,
        prove_cmd => [
            'prove', '-qf', '-Ilib', '-I/app',
            '-I/app/local/lib/perl5',
            sub { glob 'test_*.t' }
        ],
        prove_dir => '/app/qa/t',
    );
}

sub cmd_shell   { run( 'bash',  '-l' ); }
sub cmd_prove   {
    my (@args) = @_;
    run( 'prove', '-I/app', '-I/app/local/lib/perl5', @args );
}
sub cmd_version { run( 'cat',   '/app/version.json' ); }

sub cmd_test_bmo {
    my (@prove_args) = @_;
    check_data_dir();
    wait_for_db();

    $ENV{BZ_TEST_NEWBIE} = 'newbie@mozilla.example';
    $ENV{BZ_TEST_NEWBIE_PASS} = 'captain.space.bagel.ROBOT!';
    create_user($ENV{BZ_TEST_NEWBIE}, $ENV{BZ_TEST_NEWBIE_PASS}, realname => 'Newbie User');

    $ENV{BZ_TEST_NEWBIE2} = 'newbie2@mozilla.example';
    $ENV{BZ_TEST_NEWBIE2_PASS} = 'captain.space.pants.time.lord';

    prove_with_httpd(
        httpd_url => $ENV{BZ_BASE_URL},
        httpd_cmd => [ '/usr/sbin/httpd', '-f', '/app/httpd/httpd.conf',  '-DFOREGROUND' ],
        prove_cmd => [ 'prove', '-I/app', '-I/app/local/lib/perl5', @prove_args ],
    );
}

sub prove_with_httpd {
    my (%param) = @_;

    check_httpd_env();

    unless (-d '/app/logs') {
        mkdir '/app/logs' or die "unable to mkdir(/app/logs): $!\n";
    }

    my $httpd_cmd = $param{httpd_cmd};
    my $prove_cmd = $param{prove_cmd};

    my $loop = IO::Async::Loop->new;

    my $httpd_exit_f = $loop->new_future;
    say 'starting httpd';
    my $httpd = IO::Async::Process->new(
        code => sub {
            setsid();
            exec @$httpd_cmd;
        },
        setup => [
             stdout => ['open', '>', '/app/logs/access.log'],
             stderr => ['open', '>', '/app/logs/error.log'],
        ],
        on_finish => on_finish($httpd_exit_f),
        on_exception => on_exception('httpd', $httpd_exit_f),
    );
    $loop->add($httpd);
    wait_for_httpd( $httpd, $param{httpd_url} );

    warn "httpd started, starting prove\n";

    my $prove_exit_f = $loop->new_future;
    my $prove = IO::Async::Process->new(
        code => sub {
            chdir $param{prove_dir} if $param{prove_dir};
            my @cmd = (map { ref $_ eq 'CODE' ? $_->() : $_ } @$prove_cmd);
            warn "run @cmd\n";
            exec @cmd;
        },
        on_finish    => on_finish($prove_exit_f),
        on_exception => on_exception('prove', $prove_exit_f),
    );
    $loop->add($prove);

    my $prove_exit = $prove_exit_f->get();
    if ($httpd->is_running) {
        $httpd->kill('TERM');
        my $httpd_exit = $httpd_exit_f->get();
        warn "httpd exit code: $httpd_exit\n" if $httpd_exit != 0;
    }

    exit $prove_exit;
}

sub wait_for_httpd {
    my ($process, $url) = @_;
    my $loop = IO::Async::Loop->new;
    my $is_running_f = $loop->new_future;
    my $ticks = 0;
    my $run_checker = IO::Async::Timer::Periodic->new(
        first_interval => 0,
        interval       => 1,
        reschedule     => 'hard',
        on_tick        => sub {
            my ($timer) = @_;
            if ( $process->is_running ) {
                my $resp = get("$url/__lbheartbeat__");
                if ($resp && $resp =~ /^httpd OK/) {
                    $timer->stop;
                    $is_running_f->done($resp);
                }
                say "httpd doesn't seem to be up at $url. waiting...";
            }
            elsif ( $process->is_exited ) {
                $timer->stop;
                $is_running_f->fail('httpd process exited early');
            }
            elsif ( $ticks++ > 60 ) {
                $timer->stop;
                $is_running_f->fail("is_running_future() timeout after $ticks seconds");
            }
            $timer->stop if $ticks++ > 60;
        },
    );
    $loop->add($run_checker->start);
    return $is_running_f->get();
}

sub copy_qa_extension {
    say 'copying the QA extension...';
    dircopy('/app/qa/extensions/QA', '/app/extensions/QA');
}

sub wait_for_db {
    my $c = Bugzilla::Install::Localconfig::read_localconfig();
    for my $var (qw(db_name db_host db_user db_pass)) {
        die "$var is not set!" unless $c->{$var};
    }

    my $dsn = "dbi:mysql:database=$c->{db_name};host=$c->{db_host}";
    my $dbh;
    foreach (1..12) {
        say 'checking database...' if $_ > 1;
        $dbh = DBI->connect(
            $dsn,
            $c->{db_user},
            $c->{db_pass},
            { RaiseError => 0, PrintError => 0 }
        );
        last if $dbh;
        say "database $dsn not available, waiting...";
        sleep 10;
    }
    die "unable to connect to $dsn as $c->{db_user}\n" unless $dbh;
}

sub on_exception {
    my ($name, $f) = @_;
    return sub {
        my ( $self, $exception, $errno, $exitcode ) = @_;

        if ( length $exception ) {
            $f->fail("$name died with the exception $exception " . "(errno was $errno)\n");
        }
        elsif ( ( my $status = WEXITSTATUS($exitcode) ) == 255 ) {
            $f->fail("$name failed to exec() - $errno\n");
        }
        else {
            $f->fail("$name exited with exit status $status\n");
        }
    };
}

sub on_finish {
    my ($f) = @_;
    return sub {
        my ($self, $exitcode) = @_;
        say "exit code: $exitcode";
        $f->done(WEXITSTATUS($exitcode));
    };
}

sub check_user {
    die 'Effective UID must be 10001!' unless $EUID == 10_001;
    my $user = getpwuid($EUID)->name;
    die "Name of EUID must be app, not $user" unless $user eq 'app';
}

sub check_data_dir {
    die "/app/data must be writable by user 'app' (id: $EUID)" unless -w '/app/data';
    die '/app/data/params must exist' unless -f '/app/data/params';
}

sub check_env {
    my (@require_env) = @_;
    my @missing_env = grep { not exists $ENV{$_} } @require_env;
    if (@missing_env) {
        die 'Missing required environmental variables: ', join(', ', @missing_env), "\n";
    }
}
sub check_httpd_env {
    check_env(qw(
        HTTPD_StartServers
        HTTPD_MinSpareServers
        HTTPD_MaxSpareServers
        HTTPD_ServerLimit
        HTTPD_MaxClients
        HTTPD_MaxRequestsPerChild
    ))
}

sub fix_path {
    $ENV{PATH} = "/app/local/bin:$ENV{PATH}";
}

sub run {
    my (@cmd) = @_;
    say "+ @cmd";
    my $rv = system @cmd;
    if ($rv != 0) {
        exit 1;
    }
}
