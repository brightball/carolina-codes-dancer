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

use JSON;
use Plack::Test;
use HTTP::Request::Common;
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
}

my $src = do {
    open my $fh, '<', "$FindBin::Bin/../lib/CarolinaCodes/Dancer.pm" or die $!;
    local $/;
    <$fh>;
};
expect($src =~ /use Dancer2/,              'shipped app uses Dancer2');
expect($src !~ /HTTP::Daemon/,             'shipped app is not HTTP::Daemon');
expect($src =~ /FRAMEWORK\s*=>\s*'Dancer2'/, 'identity framework is Dancer2');
expect($src =~ /LANGUAGE\s*=>\s*'Perl'/,   'identity language is Perl');
expect(CarolinaCodes::Dancer::listen_host() eq '::', 'listen host is ::');

my $app = CarolinaCodes::Dancer->to_app;
expect(ref $app eq 'CODE', 'to_app returns a PSGI app');

my $test = Plack::Test->create($app);
my $json = JSON->new->utf8;

CarolinaCodes::Dancer::reset_counts();
my $health = $test->request(GET '/health');
expect($health->code == 200, '/health returns 200');
my $hbody = eval { $json->decode($health->decoded_content) } || {};
expect(($health->decoded_content // '') =~ /"status"/, '/health JSON has status');
expect(($health->decoded_content // '') =~ /"ok"/,     '/health JSON has ok');
expect(($hbody->{status} // '') eq 'ok',               '/health status is ok');
expect($CarolinaCodes::Dancer::SQL_COUNT == 0,         '/health does not run SQL');
expect($CarolinaCodes::Dancer::CONNECT_COUNT == 0,     '/health does not open Postgres');

my $root = $test->request(GET '/');
expect($root->code == 200, 'GET / returns 200');
my $identity = eval { $json->decode($root->decoded_content) } || {};
expect(($identity->{language}  // '') eq 'Perl',    'GET / language is Perl');
expect(($identity->{framework} // '') eq 'Dancer2', 'GET / framework is Dancer2');
expect($CarolinaCodes::Dancer::SQL_COUNT == 0,      'GET / does not run SQL');

my $live = eval { CarolinaCodes::Dancer::dbh(); 1 };
if (!$live) {
    warn "postgres unavailable, using query hook: $@\n";
    $CarolinaCodes::Dancer::CONNECT_FN = sub { die 'fake connect' };
    $CarolinaCodes::Dancer::QUERY_FN   = sub {
        my ($sql, $bind) = @_;
        if ($sql =~ /FROM v1_speakers WHERE slug =/) {
            return [];
        }
        if ($sql =~ /FROM v1_speakers/) {
            return [
                {
                    slug       => 'diana-pham',
                    first_name => 'Diana',
                    last_name  => 'Pham',
                    name       => 'Diana Pham',
                }
            ];
        }
        if ($sql =~ /FROM v1_talks/ && $sql =~ /DISTINCT year/) {
            return [ { year => 2026 } ];
        }
        if ($sql =~ /FROM v1_talks/) {
            return [
                {
                    slug         => 'talk',
                    title        => 'Talk',
                    speaker_slug => 'diana-pham',
                    year         => 2026,
                    languages    => ['perl'],
                    topics       => ['development'],
                }
            ];
        }
        if ($sql =~ /FROM v1_year_sponsors/) {
            return [
                {
                    slug => 'flywheel',
                    name => 'Flywheel',
                    tier => 'platinum',
                    year => 2026,
                }
            ];
        }
        if ($sql =~ /FROM v1_sponsors WHERE slug/) {
            return [];
        }
        return [];
    };
}

CarolinaCodes::Dancer::reset_counts();
my $missing = $test->request(GET '/v1/speakers/no-such-slug');
expect($missing->code == 404, 'unknown speaker slug returns 404');
expect(($missing->decoded_content // '') =~ /not_found/, '404 body is not_found');

CarolinaCodes::Dancer::reset_counts();
my $speakers = $test->request(GET '/v1/speakers?year=2026');
expect($speakers->code == 200, 'year-scoped speakers return 200');
my $spayload = eval { $json->decode($speakers->decoded_content) } || {};
my $sdata    = (ref $spayload->{data} eq 'ARRAY') ? $spayload->{data} : [];
expect(exists $spayload->{data}, 'year-scoped speakers wrapped as {data: ...}');
if (@$sdata) {
    my $row = $sdata->[0];
    expect(ref $row->{languages} eq 'ARRAY', 'year-scoped speaker row has languages');
    expect(ref $row->{topics} eq 'ARRAY',    'year-scoped speaker row has topics');
    expect(@{ $row->{languages} || [] } > 0 || !$live,
        'year-scoped speaker languages come from v1_talks merge');
}
else {
    expect(0, 'year-scoped speakers returned rows');
}
expect($CarolinaCodes::Dancer::SQL_COUNT > 0, 'year-scoped list hits catalog SQL');

CarolinaCodes::Dancer::reset_counts();
my $sponsors = $test->request(GET '/v1/sponsors?year=2026');
expect($sponsors->code == 200, 'year-scoped sponsors return 200');
my $ypayload = eval { $json->decode($sponsors->decoded_content) } || {};
my $ydata    = (ref $ypayload->{data} eq 'ARRAY') ? $ypayload->{data} : [];
expect(exists $ypayload->{data}, 'year-scoped sponsors wrapped as {data: ...}');
if (@$ydata) {
    expect(exists $ydata->[0]{tier}, 'year-scoped sponsor row includes tier');
}
else {
    expect(0, 'year-scoped sponsors returned rows');
}

my $reg_src = $src;
expect($reg_src =~ /sub register_with_elixir/, 'register_with_elixir exists');
expect($reg_src =~ /internal\/api-endpoints\/register/, 'register hits Elixir register path');

if ($failed) {
    warn "handler tests failed\n";
    exit 1;
}
warn "handler tests passed\n";
exit 0;
