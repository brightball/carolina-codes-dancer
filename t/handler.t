#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/../lib";

BEGIN {
    $ENV{DANCER_TESTING} = 1;
    $ENV{HARNESS_ACTIVE} = 1 unless defined $ENV{HARNESS_ACTIVE};
}

use IO::Socket::INET;
use JSON;
use POSIX ();
use Plack::Test;
use HTTP::Request::Common;
use Time::HiRes qw(time);
use CarolinaCodes::Dancer;

my $failed = 0;

sub expect {
    my ($cond, $msg) = @_;
    if ($cond) {
        warn "ok: $msg\n";
    }
    else {
        warn "FAIL: $msg\n";
        $failed = 1;
    }
    return;
}

sub slurp_rel {
    my ($rel) = @_;
    open my $fh, '<', "$FindBin::Bin/../$rel" or die "read $rel: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub speaker_row {
    return {
        slug         => 'diana-pham',
        first_name   => 'Diana',
        last_name    => 'Pham',
        name         => 'Diana Pham',
        tagline      => 'speaker',
        bio          => 'bio',
        company      => 'Example',
        location     => 'Raleigh',
        photo_path   => '/diana.jpg',
        twitter_url  => undef,
        linkedin_url => undef,
        website_url  => undef,
        github_url   => undef,
        featured     => 1,
    };
}

sub talk_row {
    return {
        slug         => 'talk',
        title        => 'Talk',
        description  => 'A talk',
        format       => 'talk',
        youtube_id   => undef,
        year         => 2026,
        speaker_slug => 'diana-pham',
        languages    => ['perl'],
        topics       => ['development'],
    };
}

sub sponsor_row {
    return {
        slug          => 'flywheel',
        name          => 'Flywheel',
        website       => 'https://example.test',
        logo_path     => '/flywheel.png',
        description   => 'sponsor',
        twitter_url   => undef,
        linkedin_url  => undef,
        youtube_url   => undef,
        instagram_url => undef,
        facebook_url  => undef,
    };
}

sub year_sponsor_row {
    return {
        %{ sponsor_row() },
        blurb    => 'thanks',
        tier     => 'platinum',
        featured => 1,
        year     => 2026,
    };
}

sub catalog_rows {
    my ($sql, $bind) = @_;
    my $first  = $bind->[0];
    my $second = $bind->[1];

    if ($sql =~ /FROM v1_years\b/) {
        return [ { year => 2026, slug => '2026', name => 'Twenty Twenty Six', status => 'published' } ];
    }
    if ($sql =~ /FROM v1_speakers WHERE slug =/) {
        return [] if ($first // '') ne 'diana-pham';
        return [ speaker_row() ];
    }
    if ($sql =~ /FROM v1_speakers\b/) {
        return [ speaker_row() ];
    }
    if ($sql =~ /DISTINCT speaker_slug, year FROM v1_talks/) {
        return [ { speaker_slug => 'diana-pham', year => 2026 } ];
    }
    if ($sql =~ /DISTINCT year FROM v1_talks/) {
        return [] if defined $first && $first ne 'diana-pham';
        return [ { year => 2026 } ];
    }
    if ($sql =~ /FROM v1_talks WHERE speaker_slug = \? AND year =/) {
        return [] if ($first // '') ne 'diana-pham';
        return [ talk_row() ];
    }
    if ($sql =~ /FROM v1_talks WHERE year =/) {
        return [ talk_row() ];
    }
    if ($sql =~ /FROM v1_talks WHERE speaker_slug =/) {
        return [] if ($first // '') ne 'diana-pham';
        return [ talk_row() ];
    }
    if ($sql =~ /FROM v1_year_sponsors WHERE year = \? AND slug =/) {
        return [] if ($second // '') ne 'flywheel';
        return [ year_sponsor_row() ];
    }
    if ($sql =~ /FROM v1_year_sponsors\b/) {
        return [ year_sponsor_row() ];
    }
    if ($sql =~ /FROM v1_sponsors WHERE slug =/) {
        return [] if ($first // '') ne 'flywheel';
        return [ sponsor_row() ];
    }
    if ($sql =~ /FROM v1_sponsors\b/) {
        return [ sponsor_row() ];
    }
    if ($sql =~ /FROM v1_sponsorships WHERE sponsor_slug =/) {
        return [] if defined $first && $first ne 'flywheel';
        return [ { sponsor_slug => 'flywheel', year => 2026, tier => 'platinum' } ];
    }
    return [];
}

my $src = slurp_rel('lib/CarolinaCodes/Dancer.pm');
expect($src =~ /use Dancer2/,                'shipped app uses Dancer2');
expect($src !~ /HTTP::Daemon/,               'shipped app is not HTTP::Daemon');
expect($src =~ /FRAMEWORK\s*=>\s*'Dancer2'/, 'identity framework is Dancer2');
expect($src =~ /LANGUAGE\s*=>\s*'Perl'/,     'identity language is Perl');
expect(CarolinaCodes::Dancer::listen_host() eq '::', 'listen host is ::');
expect($src =~ /sub register_with_elixir/,          'register_with_elixir exists');
expect($src =~ /internal\/api-endpoints\/register/, 'register hits Elixir register path');
expect($src =~ /sub start_register_with_elixir/,    'registration can run off the listen path');
expect($src =~ /connect_timeout/,                   'DSN sets a connect timeout');

my $psgi = slurp_rel('app.psgi');
expect($psgi =~ /start_register_with_elixir/,                        'app.psgi schedules registration');
expect($psgi !~ /^CarolinaCodes::Dancer::register_with_elixir\(\)/m, 'app.psgi does not block on registration');

my $app = CarolinaCodes::Dancer->to_app;
expect(ref $app eq 'CODE', 'to_app returns a PSGI app');

my $test = Plack::Test->create($app);
my $json = JSON->new->utf8;

sub decoded {
    my ($res) = @_;
    return eval { $json->decode($res->decoded_content // '') } || {};
}

sub polyglot {
    my ($res, $label) = @_;
    expect(($res->header('X-Polyglot-Language')  // '') eq 'Perl',    "$label sets X-Polyglot-Language: Perl");
    expect(($res->header('X-Polyglot-Framework') // '') eq 'Dancer2', "$label sets X-Polyglot-Framework: Dancer2");
    return;
}

sub expect_not_found {
    my ($path) = @_;
    my $res = $test->request(GET $path);
    expect($res->code == 404, "$path returns 404");
    my $body = decoded($res);
    expect(($body->{error} // '') eq 'not_found', "$path body is not_found");
    polyglot($res, $path);
    return;
}

CarolinaCodes::Dancer::reset_counts();
my $health = $test->request(GET '/health');
expect($health->code == 200, '/health returns 200');
my $hbody = decoded($health);
expect(($hbody->{status} // '') eq 'ok',           '/health status is ok');
expect($CarolinaCodes::Dancer::SQL_COUNT == 0,     '/health does not run SQL');
expect($CarolinaCodes::Dancer::CONNECT_COUNT == 0, '/health does not open Postgres');
polyglot($health, '/health');

CarolinaCodes::Dancer::reset_counts();
my $root = $test->request(GET '/');
expect($root->code == 200, 'GET / returns 200');
my $identity = decoded($root);
expect(($identity->{language} // '') eq 'Perl',     'GET / language is Perl');
expect(($identity->{framework} // '') eq 'Dancer2', 'GET / framework is Dancer2');
expect($CarolinaCodes::Dancer::SQL_COUNT == 0,      'GET / does not run SQL');
expect($CarolinaCodes::Dancer::CONNECT_COUNT == 0,  'GET / does not open Postgres');
polyglot($root, 'GET /');

my @captured_sql;
$CarolinaCodes::Dancer::QUERY_FN = sub {
    my ($sql, $bind) = @_;
    push @captured_sql, $sql;
    return catalog_rows($sql, $bind);
};

CarolinaCodes::Dancer::reset_counts();
my $years = $test->request(GET '/v1/years');
expect($years->code == 200, 'GET /v1/years returns 200');
my $years_body = decoded($years);
expect(ref $years_body->{data} eq 'ARRAY' && @{ $years_body->{data} }, 'GET /v1/years returns data');
expect(($years_body->{data}[0]{year} // 0) == 2026,                    'GET /v1/years returns a catalog year');
polyglot($years, 'GET /v1/years');
expect($CarolinaCodes::Dancer::CONNECT_COUNT == 0, 'fake catalog does not open Postgres');

my $speakers = $test->request(GET '/v1/speakers');
expect($speakers->code == 200, 'GET /v1/speakers returns 200');
my $speakers_body = decoded($speakers);
expect(($speakers_body->{data}[0]{slug} // '') eq 'diana-pham', 'GET /v1/speakers returns the catalog speaker');
polyglot($speakers, 'GET /v1/speakers');

@captured_sql = ();
my $year_speakers = $test->request(GET '/v1/speakers?year=2026');
expect($year_speakers->code == 200, 'year-scoped speakers return 200');
my $year_speakers_body = decoded($year_speakers);
my $year_speaker       = $year_speakers_body->{data}[0] || {};
expect(($year_speaker->{slug} // '') eq 'diana-pham', 'year-scoped speakers return the catalog speaker');
expect((ref $year_speaker->{languages} eq 'ARRAY' && grep { $_ eq 'perl' } @{ $year_speaker->{languages} || [] }),
    'year-scoped speaker row exposes talk languages');
expect((ref $year_speaker->{topics} eq 'ARRAY' && grep { $_ eq 'development' } @{ $year_speaker->{topics} || [] }),
    'year-scoped speaker row exposes talk topics');
expect((grep {/FROM v1_talks/} @captured_sql) > 0, 'year-scoped speakers read v1_talks');
polyglot($year_speakers, 'GET /v1/speakers?year=2026');

my $speaker = $test->request(GET '/v1/speakers/diana-pham');
expect($speaker->code == 200, 'GET /v1/speakers/:slug returns 200');
my $speaker_body = decoded($speaker);
expect(($speaker_body->{data}{slug} // '') eq 'diana-pham', 'GET /v1/speakers/:slug returns the speaker');
expect(ref $speaker_body->{data}{talks} eq 'ARRAY' && @{ $speaker_body->{data}{talks} },
    'GET /v1/speakers/:slug includes talks');
polyglot($speaker, 'GET /v1/speakers/:slug');

my $year_speaker_detail = $test->request(GET '/v1/speakers/2026/diana-pham');
expect($year_speaker_detail->code == 200, 'GET /v1/speakers/:year/:slug returns 200');
my $detail = decoded($year_speaker_detail)->{data} || {};
expect(($detail->{slug} // '') eq 'diana-pham', 'GET /v1/speakers/:year/:slug returns the speaker');
expect(($detail->{year} // 0) == 2026,          'GET /v1/speakers/:year/:slug returns the year');
expect((ref $detail->{languages} eq 'ARRAY' && grep { $_ eq 'perl' } @{ $detail->{languages} || [] }),
    'year-scoped speaker detail exposes talk languages');
expect((ref $detail->{topics} eq 'ARRAY' && grep { $_ eq 'development' } @{ $detail->{topics} || [] }),
    'year-scoped speaker detail exposes talk topics');
polyglot($year_speaker_detail, 'GET /v1/speakers/:year/:slug');

my $sponsors = $test->request(GET '/v1/sponsors');
expect($sponsors->code == 200, 'GET /v1/sponsors returns 200');
my $sponsors_body = decoded($sponsors);
expect(($sponsors_body->{data}[0]{slug} // '') eq 'flywheel', 'GET /v1/sponsors returns the catalog sponsor');
polyglot($sponsors, 'GET /v1/sponsors');

@captured_sql = ();
my $year_sponsors = $test->request(GET '/v1/sponsors?year=2026');
expect($year_sponsors->code == 200, 'year-scoped sponsors return 200');
my $year_sponsor = decoded($year_sponsors)->{data}[0] || {};
expect(($year_sponsor->{slug} // '') eq 'flywheel', 'year-scoped sponsors return the catalog sponsor');
expect(($year_sponsor->{tier} // '') eq 'platinum', 'year-scoped sponsor row includes tier');
expect(
    (grep { /v1_year_sponsors/ && /\btier\b/ } @captured_sql) > 0,
    'year-scoped sponsors query selects tier from v1_year_sponsors'
);
polyglot($year_sponsors, 'GET /v1/sponsors?year=2026');

my $sponsor = $test->request(GET '/v1/sponsors/flywheel');
expect($sponsor->code == 200, 'GET /v1/sponsors/:slug returns 200');
my $sponsor_body = decoded($sponsor);
expect(($sponsor_body->{data}{slug} // '') eq 'flywheel',  'GET /v1/sponsors/:slug returns the sponsor');
expect(ref $sponsor_body->{data}{sponsorships} eq 'ARRAY', 'GET /v1/sponsors/:slug includes sponsorships');
polyglot($sponsor, 'GET /v1/sponsors/:slug');

my $year_sponsor_detail = $test->request(GET '/v1/sponsors/2026/flywheel');
expect($year_sponsor_detail->code == 200, 'GET /v1/sponsors/:year/:slug returns 200');
my $sponsor_detail = decoded($year_sponsor_detail)->{data} || {};
expect(($sponsor_detail->{slug} // '') eq 'flywheel', 'GET /v1/sponsors/:year/:slug returns the sponsor');
expect(($sponsor_detail->{tier} // '') eq 'platinum', 'GET /v1/sponsors/:year/:slug includes tier');
polyglot($year_sponsor_detail, 'GET /v1/sponsors/:year/:slug');

expect_not_found('/v1/speakers/no-such-slug');
expect_not_found('/v1/sponsors/no-such-sponsor');
expect_not_found('/v1/speakers/2026/no-such-slug');
expect_not_found('/v1/sponsors/2026/no-such-sponsor');
expect_not_found('/not-a-real-route');

{
    local $CarolinaCodes::Dancer::QUERY_FN = undef;
    local $CarolinaCodes::Dancer::DBH      = undef;
    my @handles;
    local $CarolinaCodes::Dancer::CONNECT_FN = sub {
        my $gen    = @handles + 1;
        my $handle = TestCatalogConn->new(
            rows => sub {
                my ($sql) = @_;
                return [] unless $sql =~ /FROM v1_years/;
                my $year = $gen == 1 ? 2026 : 2025;
                return [ { year => $year, slug => "$year", name => "Y$year", status => 'published' } ];
            },
        );
        push @handles, $handle;
        return $handle;
    };

    CarolinaCodes::Dancer::reset_counts();
    my $first  = $test->request(GET '/v1/years');
    my $second = $test->request(GET '/v1/years');
    expect($first->code == 200 && $second->code == 200,      'catalog queries succeed on a reused connection');
    expect((decoded($first)->{data}[0]{year} // 0) == 2026,  'first catalog query returns data');
    expect((decoded($second)->{data}[0]{year} // 0) == 2026, 'reused connection returns data');
    expect($CarolinaCodes::Dancer::CONNECT_COUNT == 1,       'second catalog query does not open another connection');
    expect(@handles == 1,                                    'one connection serves both catalog queries');
    expect($handles[0]{pings} == 0,                          'catalog queries do not ping');

    $handles[0]{fail} = 1;
    my $third      = $test->request(GET '/v1/years');
    my $third_body = decoded($third);
    expect(@handles == 2,                              'dead connection is replaced');
    expect($CarolinaCodes::Dancer::CONNECT_COUNT == 2, 'dead connection opens one replacement');
    expect($third->code == 200,                        'query after a dead connection returns 200');
    expect(($third_body->{data}[0]{year} // 0) == 2025,
        'query after a dead connection returns the new connection data');
    expect($handles[0]{pings} == 1, 'a failed query checks the dead connection once');
    expect($handles[1]{pings} == 0, 'the replacement connection is used without a ping');

    CarolinaCodes::Dancer::reset_counts();
    my $health_again = $test->request(GET '/health');
    my $root_again   = $test->request(GET '/');
    expect($health_again->code == 200 && (decoded($health_again)->{status} // '') eq 'ok',
        '/health stays ok while a catalog connection is open');
    expect($root_again->code == 200 && (decoded($root_again)->{language} // '') eq 'Perl',
        'GET / stays Perl while a catalog connection is open');
    expect($CarolinaCodes::Dancer::SQL_COUNT == 0,     '/health and / do not run SQL while a catalog handle is open');
    expect($CarolinaCodes::Dancer::CONNECT_COUNT == 0, '/health and / do not connect while a catalog handle is open');
}

{
    local $CarolinaCodes::Dancer::QUERY_FN = undef;
    local $CarolinaCodes::Dancer::DBH      = undef;
    my @handles;
    local $CarolinaCodes::Dancer::CONNECT_FN = sub {
        my $handle = TestCatalogConn->new(error => "ERROR: syntax error at or near SELECT\n");
        push @handles, $handle;
        return $handle;
    };
    CarolinaCodes::Dancer::reset_counts();
    my $bad = $test->request(GET '/v1/years');
    expect(@handles == 1,                              'a SQL error does not open another connection');
    expect($CarolinaCodes::Dancer::CONNECT_COUNT == 1, 'a SQL error connects once');
    expect(($bad->code // 0) >= 500,                   'a SQL error is not reported as success');
}

my ($dsn, $dsn_user, $dsn_pass)
    = CarolinaCodes::Dancer::parse_db_url('postgres://alice:pw@db.example:5433/app?sslmode=require');
expect(($dsn_user // '') eq 'alice', 'parse_db_url keeps the user');
expect(($dsn_pass // '') eq 'pw',    'parse_db_url keeps the password');
expect($dsn =~ /host=db\.example/, 'parse_db_url keeps the host');
expect($dsn =~ /sslmode=require/,  'parse_db_url keeps sslmode');
my ($timeout) = $dsn =~ /connect_timeout=(\d+)/;
expect(defined $timeout && $timeout >= 1 && $timeout <= 3, 'parse_db_url bounds connect_timeout within 3s');
my ($dbi_dsn) = CarolinaCodes::Dancer::parse_db_url('dbi:Pg:host=db;dbname=app');
expect($dbi_dsn =~ /connect_timeout=\d+/, 'a dbi DSN gets a connect timeout');

{
    my $listen = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 5,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) or die "listen: $!";
    my $port = $listen->sockport;
    my $pid  = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        local $SIG{TERM} = sub { POSIX::_exit(0) };
        while (my $client = $listen->accept) {
            sleep 30 while $client;
        }
        POSIX::_exit(0);
    }

    # Keep this process's listen fd open so the port stays up while libpq waits.
    local $ENV{DATABASE_URL}                 = 'postgres://postgres:postgres@127.0.0.1:' . $port . '/carolina_dev';
    local $CarolinaCodes::Dancer::DBH        = undef;
    local $CarolinaCodes::Dancer::CONNECT_FN = undef;
    local $CarolinaCodes::Dancer::QUERY_FN   = undef;

    my $alarmed = 0;
    local $SIG{ALRM} = sub { $alarmed = 1; die "connect hung\n" };
    alarm 5;
    my $started = time();
    my $ok      = eval { CarolinaCodes::Dancer::open_connection(); 1 };
    my $err     = $@ || '';
    alarm 0;
    my $elapsed = time() - $started;
    kill 'TERM', $pid;
    waitpid $pid, 0;
    close $listen;

    my $timed_out = $err =~ /timeout expired/i;
    expect(!$ok,                      'unresponsive database connect fails');
    expect($timed_out,                "unresponsive database connect fails with a timeout ($err)");
    expect(!$alarmed && $elapsed < 3, "unresponsive database connect failed within 3s ($elapsed)");
    expect($elapsed >= 1,             'unresponsive database connect waited for the driver timeout');
}

my $fly = slurp_rel('fly.toml');
expect($fly =~ /auto_stop_machines\s*=\s*"suspend"/, 'fly autostop suspends machines');
expect($fly =~ /auto_start_machines\s*=\s*true/,     'fly autostart is true');
expect($fly =~ /min_machines_running\s*=\s*0/,       'fly scales to zero');
expect($fly !~ /swap/i,                              'fly.toml does not add swap');
my ($mem_n, $mem_unit) = $fly =~ /memory\s*=\s*"(\d+)(mb|gb)"/i;
my $mem_mb = defined $mem_n ? ($mem_unit =~ /gb/i ? $mem_n * 1024 : $mem_n) : 99_999;
expect($mem_mb > 0 && $mem_mb <= 2048, "fly vm memory is at most 2GB ($mem_mb)");

my $docker      = slurp_rel('Dockerfile');
my @cpanm_lines = grep {/\bcpanm\s+/} split /\n/, $docker;
expect(@cpanm_lines == 1, 'Dockerfile has one cpanm command');
expect(($cpanm_lines[0] // '') =~ /cpanm\s+--notest\s+--installdeps\s+\./, 'image installs runtime deps from cpanfile');
expect(($cpanm_lines[0] // '') !~ /--with-develop/,                        'image install omits develop dependencies');
my $copy_at  = index($docker, 'COPY cpanfile');
my $cpanm_at = index($docker, 'cpanm');
expect($copy_at >= 0 && $cpanm_at > $copy_at, 'cpanfile is copied before cpanm runs');

for my $mod (qw(Dancer2 Plack DBD::Pg Perl::Critic Perl::Tidy CPAN::Audit)) {
    expect($docker !~ /\b\Q$mod\E\b/, "Dockerfile does not hardcode $mod");
}

if ($failed) {
    warn "handler tests failed\n";
    exit 1;
}
warn "handler tests passed\n";
exit 0;

package TestCatalogConn;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        Active => 1,
        pings  => 0,
        fail   => 0,
        error  => $args{error},
        rows   => $args{rows},
    }, $class;
}

sub ping {
    my ($self) = @_;
    $self->{pings}++;
    return $self->{Active} ? 1 : 0;
}

sub selectall_arrayref {
    my ($self, $sql, $attr, @bind) = @_;
    if ($self->{fail}) {
        $self->{fail}   = 0;
        $self->{Active} = 0;
        die "server closed the connection unexpectedly\n";
    }
    if ($self->{error}) {
        die $self->{error};
    }
    return $self->{rows}->($sql, [@bind]);
}

1;
