#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

my $root   = "$FindBin::Bin/..";
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

sub slurp {
    my ($rel) = @_;
    my $path = "$root/$rel";
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

my $readme = slurp('README.md');

expect($readme =~ /Perl 5\.40/,      'README states Perl 5.40');
expect($readme =~ /perl:5\.40-slim/, 'README states the perl:5.40-slim image pin');
expect($readme =~ /Dancer2/,         'README names Dancer2');
expect($readme =~ />= 2\.1\.0/,      'README states the Dancer2 cpanfile floor >= 2.1.0');
expect($readme !~ /CRaC/,            'README does not claim CRaC');

my @packages = qw(
    Plack DBI DBD::Pg HTTP::Tiny JSON::MaybeXS
    Perl::Critic Perl::Tidy CPAN::Audit gitleaks
);
for my $package (@packages) {
    expect(index($readme, $package) >= 0, "README names $package");
}

if ($failed) {
    warn "readme version tests failed\n";
    exit 1;
}
warn "readme version tests passed\n";
exit 0;
