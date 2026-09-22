#!/usr/bin/env perl
use strict;
use warnings;
use Cwd        qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON::PP;
use Time::HiRes qw(sleep);
use lib "$FindBin::Bin/../local/lib/perl5";
use HTTP::Server::PSGI;

my $root   = abs_path("$FindBin::Bin/..");
my $helper = "$root/scripts/ci-prepared-tree.pl";
my $failed = 0;
my $server_pid;

END {
    my $save = $?;
    chdir '/';
    if ($server_pid) {
        kill 'TERM', $server_pid;
        waitpid $server_pid, 0;
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

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub spew {
    my ($path, $data) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $data;
    close $fh;
    return;
}

sub tar_member {
    my ($archive, $member) = @_;
    open my $fh, '-|', 'tar', '-xOf', $archive, $member or return;
    local $/;
    my $data = <$fh>;
    close $fh;
    return if $? != 0;
    return defined $data ? $data : '';
}

sub urldec {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\+/ /g;
    $s =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
    return $s;
}

sub query {
    my ($env) = @_;
    my %q;
    for my $part (split /&/, $env->{QUERY_STRING} || '') {
        my ($k, $v) = split /=/, $part, 2;
        $q{ urldec($k) } = urldec($v);
    }
    return \%q;
}

sub read_body {
    my ($env) = @_;
    my $len = $env->{CONTENT_LENGTH} || 0;
    return '' unless $len;
    my $fh  = $env->{'psgi.input'};
    my $buf = '';
    $fh->read($buf, $len);
    return $buf;
}

sub json_ok {
    my ($data) = @_;
    return [ 200, [ 'Content-Type' => 'application/json' ], [ JSON::PP->new->utf8->encode($data) ], ];
}

expect(-f $helper, 'prepared-tree helper exists');
my $src = slurp($helper);
expect($src =~ m{api/actions_pipeline/_apis/pipelines/workflows}, 'helper talks to the Gitea artifact HTTP API');
expect($src =~ /ACTIONS_RUNTIME_TOKEN/,                           'helper prefers the runner artifact token');
expect($src !~ /actions\/checkout/,                               'helper does not use actions/checkout');
expect($src =~ /sub cmd_pack/,                                    'helper packs the prepared tree');
expect($src =~ /sub cmd_upload/,                                  'helper uploads the prepared tree');
expect($src =~ /sub cmd_restore/,                                 'helper restores the prepared tree');

my $scratch = tempdir(CLEANUP => 1);
my $tree    = File::Spec->catdir($scratch, 'tree');
make_path("$tree/local/bin");
make_path("$tree/local/lib/perl5");
spew("$tree/README",               "hello-tree\n");
spew("$tree/local/bin/gitleaks",   "#!/bin/sh\necho fake-gitleaks\n");
spew("$tree/local/lib/perl5/x.pm", "package x; 1;\n");

chdir $tree                                                   or die "chdir $tree: $!";
system('git', 'init', '-q') == 0                              or die 'git init failed';
system('git', 'config', 'user.email', 'ci@example.test') == 0 or die 'git config email';
system('git', 'config', 'user.name', 'ci') == 0               or die 'git config name';
system('git', 'remote', 'add', 'origin', 'https://x-access-token:s3cret-token@example.test/org/repo.git') == 0
    or die 'git remote add';
system('git', 'add', 'README') == 0 or die 'git add';
system('git', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'init') == 0 or die 'git commit';

local $ENV{GITHUB_WORKSPACE}  = $tree;
local $ENV{GITHUB_SERVER_URL} = 'https://gitea.example.test';
local $ENV{GITHUB_REPOSITORY} = 'org/repo';
delete local $ENV{GITHUB_RUN_ID};
delete local $ENV{ACTIONS_RUNTIME_TOKEN};
delete local $ENV{GITHUB_TOKEN};
delete local $ENV{GITEA_TOKEN};

my $archive     = File::Spec->catfile($scratch, 'tree.tar.gz');
my $pack_status = system($^X, $helper, 'pack', $archive);
expect($pack_status == 0, 'pack exits 0');
expect(-s $archive,       'pack writes a non-empty archive');

my $cfg = tar_member($archive, './.git/config');
$cfg = tar_member($archive, '.git/config') unless defined $cfg;
expect(defined $cfg, 'packed archive includes .git/config for gitleaks');
expect(($cfg || '') !~ /s3cret-token/,                   'pack redacts the job token from git remote');
expect(($cfg || '') =~ m{gitea\.example\.test/org/repo}, 'pack keeps a tokenless origin URL');

{
    local $ENV{TMPDIR} = $tree;
    delete local $ENV{PREPARED_TREE_ARCHIVE};
    my $inside_status = system($^X, $helper, 'pack');
    expect($inside_status == 0, 'pack succeeds when TMPDIR is the workspace');
    opendir my $tmp, '/tmp' or die "opendir /tmp: $!";
    my @packed = grep {/^prepared-tree-.*\.tar\.gz$/} readdir $tmp;
    closedir $tmp or die "closedir /tmp: $!";
    unlink map {"/tmp/$_"} @packed;
}

my $unpacked = File::Spec->catdir($scratch, 'unpacked');
make_path($unpacked);
{
    local $ENV{GITHUB_WORKSPACE} = $unpacked;
    my $st = system($^X, $helper, 'unpack', $archive);
    expect($st == 0,                                    'unpack exits 0');
    expect(-f "$unpacked/README",                       'unpack restores first-party files');
    expect(slurp("$unpacked/README") eq "hello-tree\n", 'unpack restores file bytes');
    expect(-f "$unpacked/local/bin/gitleaks",           'unpack restores gitleaks on PATH');
    expect(-f "$unpacked/local/lib/perl5/x.pm",         'unpack restores CPAN local-lib');
    expect(-d "$unpacked/.git",                         'unpack restores the git tree');
}

{
    local $ENV{GITHUB_WORKSPACE} = $unpacked;
    my $st = system($^X, $helper, 'upload');
    expect($st != 0, 'upload fails closed without a job token');
}

{
    local $ENV{GITHUB_WORKSPACE} = $unpacked;
    local $ENV{GITHUB_TOKEN}     = 't';
    local $ENV{GITHUB_RUN_ID}    = '1';
    delete local $ENV{GITHUB_SERVER_URL};
    my $st = system($^X, $helper, 'restore');
    expect($st != 0, 'restore fails closed without GITHUB_SERVER_URL');
}

my $store = { confirmed => 0, body => '' };
my $probe = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
    Proto     => 'tcp',
    ReuseAddr => 1,
);
my $port = $probe->sockport;
close $probe;
my $base = "http://127.0.0.1:$port";
my $run  = '791';
my $hash = 'prepared';

my $app = sub {
    my $env    = shift;
    my $method = $env->{REQUEST_METHOD};
    my $path   = $env->{PATH_INFO}          || '';
    my $auth   = $env->{HTTP_AUTHORIZATION} || '';
    return [ 401, [ 'Content-Type' => 'text/plain' ], ['no auth'] ]
        unless $auth =~ /^Bearer\s+\S+/;
    my $q = query($env);

    if ($method eq 'POST' && $path =~ m{/artifacts$}) {
        my $req = JSON::PP->new->utf8->decode(read_body($env));
        return [ 400, [], ['bad name'] ] unless ($req->{Name} || '') eq 'prepared-tree';
        return json_ok(
            {   fileContainerResourceUrl =>
                    "$base/api/actions_pipeline/_apis/pipelines/workflows/$run/artifacts/$hash/upload",
            }
        );
    }
    if ($method eq 'PUT' && $path =~ m{/artifacts/$hash/upload$}) {
        $store->{body} = read_body($env);
        return json_ok({ message => 'success' });
    }
    if ($method eq 'PATCH' && $path =~ m{/artifacts$}) {
        return [ 400, [], ['missing name'] ] unless ($q->{artifactName} || '') eq 'prepared-tree';
        $store->{confirmed} = 1;
        return json_ok({ message => 'success' });
    }
    if ($method eq 'GET' && $path =~ m{/artifacts$} && $path !~ m{/artifacts/}) {
        return [ 404, [], ['none'] ] unless $store->{confirmed};
        return json_ok(
            {   count => 1,
                value => [
                    {   name                     => 'prepared-tree',
                        fileContainerResourceUrl =>
                            "$base/api/actions_pipeline/_apis/pipelines/workflows/$run/artifacts/$hash/download_url",
                    }
                ],
            }
        );
    }
    if ($method eq 'GET' && $path =~ m{/download_url$}) {
        return [ 404, [], ['none'] ] unless $store->{confirmed};
        return json_ok(
            {   value => [
                    {   path            => 'prepared-tree/tree.tar.gz',
                        itemType        => 'file',
                        contentLocation =>
                            "$base/api/actions_pipeline/_apis/pipelines/workflows/$run/artifacts/1/download",
                    }
                ],
            }
        );
    }
    if ($method eq 'GET' && $path =~ m{/download$}) {
        return [ 404, [], ['none'] ] unless $store->{confirmed} && defined $store->{body};
        return [ 200, [ 'Content-Type' => 'application/gzip' ], [ $store->{body} ] ];
    }
    return [ 404, [ 'Content-Type' => 'text/plain' ], ["no $method $path"] ];
};

$server_pid = fork;
die "fork: $!" unless defined $server_pid;
if ($server_pid == 0) {
    HTTP::Server::PSGI->new(host => '127.0.0.1', port => $port)->run($app);
    exit 0;
}

my $ready = 0;
for (1 .. 50) {
    my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
    if ($sock) {
        close $sock;
        $ready = 1;
        last;
    }
    sleep 0.05;
}
expect($ready, 'mock Gitea artifact API is listening');

my $up_tree = File::Spec->catdir($scratch, 'upload-tree');
make_path($up_tree);
{
    local $ENV{GITHUB_WORKSPACE} = $up_tree;
    my $st = system($^X, $helper, 'unpack', $archive);
    expect($st == 0, 'seed upload tree from the packed archive');
}

{
    local $ENV{GITHUB_WORKSPACE}      = $up_tree;
    local $ENV{GITHUB_SERVER_URL}     = $base;
    local $ENV{GITHUB_RUN_ID}         = $run;
    local $ENV{ACTIONS_RUNTIME_TOKEN} = 'runtime-token';
    local $ENV{GITHUB_REPOSITORY}     = 'org/repo';
    my $st = system($^X, $helper, 'upload');
    expect($st == 0, 'upload to mock artifact API exits 0');
}

my $restored = File::Spec->catdir($scratch, 'restored');
make_path($restored);
{
    local $ENV{GITHUB_WORKSPACE}      = $restored;
    local $ENV{GITHUB_SERVER_URL}     = $base;
    local $ENV{GITHUB_RUN_ID}         = $run;
    local $ENV{ACTIONS_RUNTIME_TOKEN} = 'runtime-token';
    my $st = system($^X, $helper, 'restore');
    expect($st == 0,              'restore from mock artifact API exits 0');
    expect(-f "$restored/README", 'restore writes first-party files from the artifact');
    my $restored_readme = -f "$restored/README" ? slurp("$restored/README") : '';
    expect($restored_readme eq "hello-tree\n", 'restore preserves packed bytes');
    expect(-f "$restored/local/bin/gitleaks",  'restore puts gitleaks on PATH');
    expect(-d "$restored/.git",                'restore keeps the git tree');
}

chdir $root or warn "chdir $root: $!";

if ($failed) {
    warn "prepared-tree helper tests failed\n";
    exit 1;
}
warn "prepared-tree helper tests passed\n";
exit 0;
