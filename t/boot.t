#!/usr/bin/env perl
use strict;
use warnings;
use Cwd        qw(abs_path);
use File::Temp qw(tempfile);
use FindBin;
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::IP;
use JSON::PP;
use POSIX       ();
use Time::HiRes qw(sleep time);
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/../lib";
use HTTP::Tiny;

my $root   = abs_path("$FindBin::Bin/..");
my $failed = 0;
my @pids;

END {
    my $save = $?;
    for my $item (@pids) {
        my ($pid, $group) = @$item;
        next unless $pid;
        if ($group) {
            kill 'TERM', -$pid;
        }
        else {
            kill 'TERM', $pid;
        }
        waitpid $pid, 0;
    }
    $? = $save;
}

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

sub free_port {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 1,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) or die "free port: $!";
    my $port = $sock->sockport;
    close $sock;
    return $port;
}

sub read_http_request {
    my ($client) = @_;
    my $buf = '';
    while ($buf !~ /\r\n\r\n/) {
        my $n = sysread $client, my $chunk, 4096;
        last if !defined $n || $n == 0;
        $buf .= $chunk;
        last if length $buf > 1_048_576;
    }
    if ($buf =~ /Content-Length:\s*(\d+)/i) {
        my $need       = $1;
        my $header_len = index($buf, "\r\n\r\n");
        if ($header_len >= 0) {
            my $have = length($buf) - ($header_len + 4);
            while ($have < $need) {
                my $n = sysread $client, my $chunk, $need - $have;
                last if !defined $n || $n == 0;
                $buf .= $chunk;
                $have += $n;
            }
        }
    }
    return $buf;
}

sub start_silent_peer {
    my $listen = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 16,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) or die "peer listen: $!";
    my $port = $listen->sockport;
    pipe my $rd, my $wr or die "pipe: $!";
    my $pid = fork();
    die "fork peer: $!" unless defined $pid;
    if ($pid == 0) {
        close $rd;
        $wr->autoflush(1);
        local $SIG{TERM} = sub { POSIX::_exit(0) };
        my @hold;
        while (my $client = $listen->accept) {
            push @hold, $client;
            my $buf    = read_http_request($client);
            my ($line) = split /\r\n/, $buf;
            $line = '' unless defined $line;
            $line =~ s/[^\x20-\x7e]//g;
            print {$wr} "ACCEPTED wrote=0 request=$line\n";
            my $n = sysread $client, my $extra, 1024;
            if (defined $n && $n == 0) {
                print {$wr} "CLOSED\n";
            }
        }
        POSIX::_exit(0);
    }
    close $wr;
    close $listen;
    push @pids, [ $pid, 0 ];
    return ($pid, $port, $rd);
}

sub read_for {
    my ($fh, $seconds) = @_;
    my $sel      = IO::Select->new($fh);
    my $buf      = '';
    my $deadline = time() + $seconds;
    while (time() < $deadline && $buf !~ /\n/) {
        my $left = $deadline - time();
        last if $left <= 0;
        if ($sel->can_read($left)) {
            my $n = sysread $fh, my $chunk, 4096;
            last if !defined $n || $n == 0;
            $buf .= $chunk;
        }
        else {
            last;
        }
    }
    return $buf;
}

sub read_available {
    my ($fh) = @_;
    my $sel  = IO::Select->new($fh);
    my $buf  = '';
    while ($sel->can_read(0)) {
        my $n = sysread $fh, my $chunk, 4096;
        last if !defined $n || $n == 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub host_can_bind_v6 {
    my $sock = IO::Socket::IP->new(
        LocalHost => '::',
        LocalPort => 0,
        Listen    => 1,
        ReuseAddr => 1,
        V6Only    => 0,
        Proto     => 'tcp',
    );
    return 0 unless $sock;
    close $sock or return 0;
    return 1;
}

sub server_listens_v6 {
    my ($pid, $port) = @_;
    my $hex = uc sprintf '%04X', $port;
    open my $fh, '<', "/proc/$pid/net/tcp6" or return 0;
    my $found = 0;
    while (my $line = <$fh>) {
        next unless $line =~ /:${hex}\b/i;
        my @fields = split /\s+/, $line;
        $found = 1 if grep { $_ eq '0A' } @fields;
        last if $found;
    }
    close $fh or return 0;
    return $found;
}

sub wait_listen {
    my ($port, $seconds) = @_;
    my $deadline = time() + $seconds;
    while (time() < $deadline) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 0.2,
        );
        if ($sock) {
            close $sock;
            return 1;
        }
        sleep 0.05;
    }
    return 0;
}

sub stop_server {
    my ($pid) = @_;
    return unless $pid;
    kill 'TERM', -$pid;
    my $deadline = time() + 2;
    while (time() < $deadline) {
        last if waitpid($pid, POSIX::WNOHANG()) == $pid;
        sleep 0.05;
    }
    if (kill 0, $pid) {
        kill 'KILL', -$pid;
        waitpid $pid, 0;
    }
    @pids = grep { $_->[0] != $pid } @pids;
    return;
}

sub slurp {
    my ($fh) = @_;
    seek $fh, 0, 0 or return '';
    local $/;
    my $data = <$fh>;
    return defined $data ? $data : '';
}

sub boot_once {
    my ($label) = @_;
    my ($peer_pid, $peer_port, $peer_rd) = start_silent_peer();
    my $port = free_port();
    my ($logfh, $logfile) = tempfile('dancer-boot-XXXX', SUFFIX => '.log', UNLINK => 1, TMPDIR => 1);
    $logfh->autoflush(1);

    my $pid = fork();
    die "fork server: $!" unless defined $pid;
    if ($pid == 0) {
        setpgrp(0, 0);
        open STDOUT, '>&', $logfh or POSIX::_exit(1);
        open STDERR, '>&', $logfh or POSIX::_exit(1);
        delete $ENV{HARNESS_ACTIVE};
        delete $ENV{DANCER_TESTING};
        $ENV{PORT}                    = $port;
        $ENV{CAROLINA_URL}            = "http://127.0.0.1:$peer_port";
        $ENV{POLYGLOT_REGISTER_TOKEN} = 'dev';
        $ENV{PUBLIC_BASE_URL}         = "http://127.0.0.1:$port";
        $ENV{DATABASE_URL}            = 'postgres://postgres:postgres@127.0.0.1:1/carolina_dev';
        $ENV{PERL5LIB}                = "$root/local/lib/perl5" . ($ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '');
        chdir $root or POSIX::_exit(1);
        exec $^X, "$root/bin/server" or POSIX::_exit(1);
    }
    push @pids, [ $pid, 1 ];

    my $up = wait_listen($port, 20);
    expect($up, "$label server is listening");
    if ($up && host_can_bind_v6()) {
        expect(server_listens_v6($pid, $port), "$label keeps the dual-stack listener");
    }
    if (!$up) {
        warn "$label server log:\n" . slurp($logfh) . "\n";
        stop_server($pid);
        kill 'TERM', $peer_pid;
        return;
    }

    my $ua        = HTTP::Tiny->new(timeout => 1);
    my $json      = JSON::PP->new->utf8;
    my $t0        = time();
    my $health    = $ua->get("http://127.0.0.1:$port/health");
    my $health_dt = time() - $t0;
    expect(($health->{status} // 0) == 200, "$label /health returns 200");
    expect($health_dt < 1,                  "$label /health answered in under 1s ($health_dt)");
    my $hbody = eval { $json->decode($health->{content} // '') } || {};
    expect(($hbody->{status}                           // '') eq 'ok',      "$label /health status is ok");
    expect(($health->{headers}{'x-polyglot-language'}  // '') eq 'Perl',    "$label /health language header");
    expect(($health->{headers}{'x-polyglot-framework'} // '') eq 'Dancer2', "$label /health framework header");

    my $t1       = time();
    my $root_res = $ua->get("http://127.0.0.1:$port/");
    my $root_dt  = time() - $t1;
    expect(($root_res->{status} // 0) == 200, "$label / returns 200");
    expect($root_dt < 1,                      "$label / answered in under 1s ($root_dt)");
    my $ibody = eval { $json->decode($root_res->{content} // '') } || {};
    expect(($ibody->{language}  // '') eq 'Perl',    "$label / language is Perl");
    expect(($ibody->{framework} // '') eq 'Dancer2', "$label / framework is Dancer2");

    my $peer = read_for($peer_rd, 2);
    sleep 0.2;
    $peer .= read_available($peer_rd);
    expect($peer =~ /ACCEPTED/,                          "$label registration peer accepted the register request");
    expect($peer =~ m{/internal/api-endpoints/register}, "$label registration request hits the Elixir register path");
    expect($peer =~ /wrote=0/,                           "$label registration peer wrote no response");
    expect($peer !~ /CLOSED/,                            "$label registration request is still unanswered");
    if ($peer !~ /ACCEPTED/ || ($health->{status} // 0) != 200) {
        warn "$label server log:\n" . slurp($logfh) . "\n";
        warn "$label peer said: $peer\n";
    }

    stop_server($pid);
    kill 'TERM', $peer_pid;
    waitpid $peer_pid, 0;
    @pids = grep { $_->[0] != $peer_pid } @pids;
    return;
}

boot_once('run 1');
boot_once('run 2');

if ($failed) {
    warn "boot tests failed\n";
    exit 1;
}
warn "boot tests passed\n";
exit 0;
