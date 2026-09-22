package CarolinaCodes::Dancer;
use strict;
use warnings;
use Dancer2;
use DBI;
use HTTP::Tiny;
use JSON        ();
use POSIX       ();
use URI::Escape qw(uri_unescape);

our $VERSION = '0.2.0';

use constant LANGUAGE         => 'Perl';
use constant API_VERSION      => '0.2.0';
use constant FRAMEWORK        => 'Dancer2';
use constant CREATED_YEAR     => 2026;
use constant SCHEMA_VERSION   => 1;
use constant LANGUAGE_VERSION => sprintf('%vd', $^V);

my $JSON = JSON->new->utf8->allow_nonref;

our @ENDPOINTS = (
    { method => 'GET', path => '/',                        query => [] },
    { method => 'GET', path => '/health',                  query => [] },
    { method => 'GET', path => '/v1/years',                query => [] },
    { method => 'GET', path => '/v1/speakers',             query => ['year'] },
    { method => 'GET', path => '/v1/speakers/:slug',       query => [] },
    { method => 'GET', path => '/v1/speakers/:year/:slug', query => [] },
    { method => 'GET', path => '/v1/sponsors',             query => ['year'] },
    { method => 'GET', path => '/v1/sponsors/:slug',       query => [] },
    { method => 'GET', path => '/v1/sponsors/:year/:slug', query => [] },
);

my $SPEAKER_COLS = 'slug, first_name, last_name, name, tagline, bio, company, location, '
    . 'photo_path, twitter_url, linkedin_url, website_url, github_url, featured';
my $YEAR_SPONSOR_COLS = 'slug, name, website, logo_path, description, blurb, tier, featured, year, '
    . 'twitter_url, linkedin_url, youtube_url, instagram_url, facebook_url';
my $SPONSOR_COLS = 'slug, name, website, logo_path, description, twitter_url, linkedin_url, '
    . 'youtube_url, instagram_url, facebook_url';
my $TALK_COLS = 'slug, title, description, format, youtube_id, year, speaker_slug, languages, topics';

our $DBH;
our $SQL_COUNT     = 0;
our $CONNECT_COUNT = 0;
our $CONNECT_FN;
our $QUERY_FN;
our $REGISTERED = 0;

set serializer   => 'JSON';
set charset      => 'UTF-8';
set show_errors  => 0;
set traces       => 0;
set startup_info => 0;
set logger       => ($ENV{HARNESS_ACTIVE} || $ENV{DANCER_TESTING}) ? 'Null' : 'Console';

hook after => sub {
    response_header 'X-Polyglot-Language'  => LANGUAGE;
    response_header 'X-Polyglot-Framework' => FRAMEWORK;
};

sub listen_host {'::'}

sub reset_counts {
    $SQL_COUNT     = 0;
    $CONNECT_COUNT = 0;
}

# libpq treats a connect_timeout below 2 as 2. Two seconds still fails inside the 3s bound.
sub apply_connect_timeout {
    my ($dsn) = @_;
    return $dsn if $dsn =~ /(?:^|;)connect_timeout=/;
    return $dsn . ';connect_timeout=2';
}

sub parse_db_url {
    my ($url) = @_;
    $url ||= 'postgres://postgres:postgres@127.0.0.1:5432/carolina_dev';
    if ($url =~ m{^dbi:}) {
        $url .= ';sslmode=disable' unless $url =~ /sslmode=/;
        return (apply_connect_timeout($url), undef, undef);
    }
    if ($url =~ m{^postgres(?:ql)?://
                  (?:([^:@/]+)(?::([^@/]*))?@)?
                  ([^:/]+)
                  (?::(\d+))?
                  /([^?]+)
                  (?:\?(.*))?
                 }x
        )
    {
        my ($user, $pass, $host, $port, $db, $query) = ($1, $2, $3, $4, $5, $6);
        $user = defined $user ? uri_unescape($user) : 'postgres';
        $pass = defined $pass ? uri_unescape($pass) : 'postgres';
        $port ||= 5432;
        $db =~ s/[?#].*//;
        my $dsn     = "dbi:Pg:host=$host;port=$port;dbname=$db";
        my $sslmode = 'disable';
        if ($query) {
            my %q = map { split /=/, $_, 2 } split /&/, $query;
            $sslmode = $q{sslmode} if $q{sslmode};
        }
        $dsn .= ";sslmode=$sslmode";
        return (apply_connect_timeout($dsn), $user, $pass);
    }
    return (apply_connect_timeout("dbi:Pg:dbname=$url;sslmode=disable"), undef, undef);
}

sub open_connection {
    $CONNECT_COUNT++;
    return $CONNECT_FN->() if $CONNECT_FN;
    my $url = $ENV{DATABASE_URL} // 'postgres://postgres:postgres@127.0.0.1:5432/carolina_dev';
    my ($dsn, $user, $pass) = parse_db_url($url);
    return DBI->connect(
        $dsn, $user, $pass,
        {   RaiseError     => 1,
            AutoCommit     => 1,
            pg_enable_utf8 => 1,
            PrintError     => 0,
        }
    );
}

sub dbh {
    return $DBH if $DBH;
    $DBH = open_connection();
    return $DBH;
}

# Ping only after a failed query, to tell a dead connection from bad SQL.
sub connection_alive {
    my ($dbh) = @_;
    return 0 unless $dbh;
    my $alive = eval { $dbh->ping };
    return $alive ? 1 : 0;
}

sub db_query {
    my ($sql, @bind) = @_;
    $SQL_COUNT++;
    return $QUERY_FN->($sql, \@bind) if $QUERY_FN;
    my $rows = eval { dbh()->selectall_arrayref($sql, { Slice => {} }, @bind) };
    my $err  = $@;
    return $rows if !$err;
    if (!$DBH || connection_alive($DBH)) {
        die $err;
    }
    eval { $DBH->{InactiveDestroy} = 1 };
    $DBH = undef;
    return dbh()->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub db_query_one {
    my ($sql, @bind) = @_;
    my $rows = db_query($sql, @bind);
    return $rows && @$rows ? $rows->[0] : undef;
}

sub as_string_array {
    my ($value) = @_;
    return [] unless defined $value;
    if (ref $value eq 'ARRAY') {
        return [ grep {length} map {"$_"} @$value ];
    }
    my $stripped = $value;
    $stripped =~ s/^\s+|\s+$//g;
    return [] if $stripped eq '' || $stripped eq '{}';
    if ($stripped =~ /^\{(.*)\}$/) {
        $stripped = $1;
    }
    return [
        grep {length} map {
            my $item = $_;
            $item =~ s/^"|"$//g;
            $item;
        } split /,/,
        $stripped
    ];
}

sub clean {
    my ($row) = @_;
    return unless $row;
    my %out;
    for my $key (keys %$row) {
        my $v = $row->{$key};
        if (!defined $v) {
            $out{$key} = undef;
        }
        elsif ($key eq 'languages' || $key eq 'topics') {
            $out{$key} = as_string_array($v);
        }
        elsif ($key eq 'featured') {
            $out{$key} = $v ? JSON::true : JSON::false;
        }
        elsif ($key eq 'year') {
            $out{$key} = 0 + $v;
        }
        elsif (ref $v eq 'ARRAY') {
            $out{$key} = [ map {"$_"} @$v ];
        }
        else {
            $out{$key} = $v;
        }
    }
    return \%out;
}

sub uniq_tags {
    my ($talks, $key) = @_;
    my %seen;
    my @out;
    for my $talk (@$talks) {
        for my $val (@{ as_string_array($talk->{$key}) }) {
            next if $seen{$val}++;
            push @out, $val;
        }
    }
    return \@out;
}

sub talks_for {
    my ($slug, $year) = @_;
    my $sql  = "SELECT $TALK_COLS FROM v1_talks WHERE speaker_slug = ?";
    my @bind = ($slug);
    if (defined $year) {
        $sql .= ' AND year = ?';
        push @bind, $year;
    }
    $sql .= ' ORDER BY year DESC';
    my $rows = db_query($sql, @bind);
    return [ map { clean($_) } @$rows ];
}

sub talk_years {
    my ($slug) = @_;
    my $rows = db_query('SELECT DISTINCT year FROM v1_talks WHERE speaker_slug = ? ORDER BY year DESC', $slug);
    return [ map { 0 + $_->{year} } @$rows ];
}

sub sponsor_years {
    my ($slug) = @_;
    my $rows = db_query('SELECT DISTINCT year FROM v1_sponsorships WHERE sponsor_slug = ? ORDER BY year DESC', $slug);
    return [ map { 0 + $_->{year} } @$rows ];
}

sub load_speaker {
    my ($slug) = @_;
    my $row = db_query_one("SELECT $SPEAKER_COLS FROM v1_speakers WHERE slug = ?", $slug);
    return clean($row);
}

sub list_speakers {
    my ($year) = @_;
    if (!defined $year) {
        my $rows = db_query("SELECT $SPEAKER_COLS FROM v1_speakers ORDER BY last_name, first_name");
        return [ map { clean($_) } @$rows ];
    }
    my $rows = db_query(
        "SELECT $SPEAKER_COLS FROM v1_speakers "
            . 'WHERE slug IN (SELECT speaker_slug FROM v1_talks WHERE year = ?) '
            . 'ORDER BY last_name, first_name',
        $year
    );
    return attach_year_tags([ map { clean($_) } @$rows ], $year);
}

sub attach_year_tags {
    my ($speakers, $year) = @_;
    return $speakers unless @$speakers;
    my @slugs    = map { $_->{slug} } @$speakers;
    my $talks_by = load_talks_for_year($year);
    my $years_by = load_years_for_slugs(\@slugs);
    for my $sp (@$speakers) {
        my $slug  = $sp->{slug};
        my $talks = $talks_by->{$slug} // [];
        my $years = $years_by->{$slug} // [];
        $sp->{year}      = $year;
        $sp->{talks}     = $talks;
        $sp->{languages} = uniq_tags($talks, 'languages');
        $sp->{topics}    = uniq_tags($talks, 'topics');
        $sp->{years}     = $years;
    }
    return $speakers;
}

sub load_talks_for_year {
    my ($year) = @_;
    my $rows = db_query("SELECT $TALK_COLS FROM v1_talks WHERE year = ? ORDER BY speaker_slug, year DESC", $year);
    my %by;
    for my $row (@$rows) {
        my $talk = clean($row);
        my $slug = $talk->{speaker_slug} // '';
        push @{ $by{$slug} }, $talk;
    }
    return \%by;
}

sub load_years_for_slugs {
    my ($slugs) = @_;
    return {} unless @$slugs;
    my $placeholders = join ',', ('?') x @$slugs;
    my $rows         = db_query(
        "SELECT DISTINCT speaker_slug, year FROM v1_talks WHERE speaker_slug IN ($placeholders) ORDER BY speaker_slug, year DESC",
        @$slugs
    );
    my %by;
    for my $row (@$rows) {
        push @{ $by{ $row->{speaker_slug} } }, 0 + $row->{year};
    }
    return \%by;
}

sub identity {
    return {
        language         => LANGUAGE,
        language_version => LANGUAGE_VERSION,
        api_version      => API_VERSION,
        framework        => FRAMEWORK,
        created_year     => CREATED_YEAR,
        schema_version   => SCHEMA_VERSION,
        endpoints        => \@ENDPOINTS,
    };
}

sub register_payload {
    my ($base) = @_;
    return {
        language         => LANGUAGE,
        language_version => LANGUAGE_VERSION,
        api_version      => API_VERSION,
        framework        => FRAMEWORK,
        created_year     => CREATED_YEAR,
        schema_version   => SCHEMA_VERSION,
        base_url         => $base,
        endpoints        => \@ENDPOINTS,
    };
}

# Fork the one register attempt so a stalled CMS cannot delay the listener.
sub start_register_with_elixir {
    my ($port) = @_;
    return if $REGISTERED;
    my $url   = $ENV{CAROLINA_URL};
    my $token = $ENV{POLYGLOT_REGISTER_TOKEN};
    return unless defined $url && length $url && defined $token && length $token;

    my $pid = fork();
    if (!defined $pid) {
        warn "register fork: $!\n";
        register_with_elixir($port);
        return;
    }
    if ($pid == 0) {
        my $ok = eval { register_with_elixir($port); 1 };
        warn $@ if !$ok && $@;
        POSIX::_exit(0);
    }
    $REGISTERED = 1;
    $SIG{CHLD} = 'IGNORE';
    return;
}

sub register_with_elixir {
    my ($port) = @_;
    $port //= $ENV{PORT} // '4017';
    return if $REGISTERED;
    my $url   = $ENV{CAROLINA_URL};
    my $token = $ENV{POLYGLOT_REGISTER_TOKEN};
    return unless defined $url && length $url && defined $token && length $token;
    $REGISTERED = 1;
    my $base = $ENV{PUBLIC_BASE_URL} // "http://127.0.0.1:$port";
    $url =~ s{/$}{};
    my $http = HTTP::Tiny->new(timeout => 5);
    my $resp = $http->post(
        "$url/internal/api-endpoints/register",
        {   headers => {
                Authorization  => "Bearer $token",
                'Content-Type' => 'application/json',
            },
            content => $JSON->encode(register_payload($base)),
        }
    );

    if ($resp->{success}) {
        warn "registered with elixir: $resp->{status}\n";
    }
    else {
        warn "register: $resp->{status} $resp->{reason}\n";
    }
}

get '/' => sub {
    return identity();
};

get '/health' => sub {
    return { status => 'ok' };
};

get '/v1/years' => sub {
    my $rows = db_query('SELECT year, slug, name, status FROM v1_years ORDER BY year DESC');
    return { data => [ map { clean($_) } @$rows ] };
};

get '/v1/speakers' => sub {
    my $raw = query_parameters->get('year');
    my $year;
    if (defined $raw && length $raw) {
        $year = 0 + $raw;
    }
    return { data => list_speakers($year) };
};

get '/v1/speakers/:year/:slug' => sub {
    my $year = route_parameters->get('year');
    my $slug = route_parameters->get('slug');
    unless ($year =~ /^\d+$/) {
        status 404;
        return { error => 'not_found' };
    }
    $year = 0 + $year;
    my $speaker = load_speaker($slug);
    unless ($speaker) {
        status 404;
        return { error => 'not_found' };
    }
    my $talks = talks_for($slug, $year);
    unless (@$talks) {
        status 404;
        return { error => 'not_found' };
    }
    my $years = talk_years($slug);
    $speaker->{year}        = $year;
    $speaker->{years}       = $years;
    $speaker->{other_years} = [ grep { $_ != $year } @$years ];
    $speaker->{talks}       = $talks;
    $speaker->{languages}   = uniq_tags($talks, 'languages');
    $speaker->{topics}      = uniq_tags($talks, 'topics');
    return { data => $speaker };
};

get '/v1/speakers/:slug' => sub {
    my $slug    = route_parameters->get('slug');
    my $speaker = load_speaker($slug);
    unless ($speaker) {
        status 404;
        return { error => 'not_found' };
    }
    $speaker->{talks} = talks_for($slug);
    $speaker->{years} = talk_years($slug);
    return { data => $speaker };
};

get '/v1/sponsors' => sub {
    my $raw = query_parameters->get('year');
    my $rows;
    if (defined $raw && length $raw) {
        $rows = db_query("SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = ? ORDER BY name", 0 + $raw);
    }
    else {
        $rows = db_query("SELECT $SPONSOR_COLS FROM v1_sponsors ORDER BY name");
    }
    return { data => [ map { clean($_) } @$rows ] };
};

get '/v1/sponsors/:year/:slug' => sub {
    my $year = route_parameters->get('year');
    my $slug = route_parameters->get('slug');
    unless ($year =~ /^\d+$/) {
        status 404;
        return { error => 'not_found' };
    }
    $year = 0 + $year;
    my $row = db_query_one("SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = ? AND slug = ?", $year, $slug);
    $row = clean($row);
    unless ($row) {
        status 404;
        return { error => 'not_found' };
    }
    my $years = sponsor_years($slug);
    $row->{years}       = $years;
    $row->{other_years} = [ grep { $_ != $year } @$years ];
    return { data => $row };
};

get '/v1/sponsors/:slug' => sub {
    my $slug = route_parameters->get('slug');
    my $row  = db_query_one("SELECT $SPONSOR_COLS FROM v1_sponsors WHERE slug = ?", $slug);
    $row = clean($row);
    unless ($row) {
        status 404;
        return { error => 'not_found' };
    }
    my $sponsorships = db_query('SELECT * FROM v1_sponsorships WHERE sponsor_slug = ?', $slug);
    $row->{sponsorships} = [ map { clean($_) } @$sponsorships ];
    return { data => $row };
};

any qr{.*} => sub {
    status 404;
    return { error => 'not_found' };
};

1;
