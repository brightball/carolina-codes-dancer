#!/usr/bin/env perl
use strict;
use warnings;
use Cwd         qw(getcwd);
use Digest::MD5 qw(md5);
use File::Temp  qw(tempfile);
use JSON::PP;
use MIME::Base64 qw(encode_base64);

my $ARTIFACT = $ENV{PREPARED_TREE_ARTIFACT} || 'prepared-tree';
my $TAR_NAME = 'tree.tar.gz';
my $default_archive;

my $cmd     = shift @ARGV // '';
my %handler = (
    pack    => \&cmd_pack,
    unpack  => \&cmd_unpack,
    upload  => \&cmd_upload,
    restore => \&cmd_restore,
);
die "usage: $0 pack|unpack|upload|restore [archive]\n" unless $handler{$cmd};
$handler{$cmd}->(@ARGV);
exit 0;

sub workspace {
    my $dir = $ENV{GITHUB_WORKSPACE} || getcwd();
    chdir $dir or die "chdir $dir: $!";
    return $dir;
}

sub archive_path {
    my ($arg) = @_;
    return $arg                        if defined $arg && $arg ne '';
    return $ENV{PREPARED_TREE_ARCHIVE} if $ENV{PREPARED_TREE_ARCHIVE};
    return $default_archive            if $default_archive;

    # Runners often set TMPDIR to the workspace. A tar written there is read
    # while it is still growing ("file changed as we read it").
    my ($fh, $path) = tempfile('prepared-tree-XXXXXX', SUFFIX => '.tar.gz', DIR => '/tmp', UNLINK => 0);
    close $fh or die "close $path: $!";
    $default_archive = $path;
    return $default_archive;
}

sub redact_git_remote {
    return unless -d '.git';
    my $url  = $ENV{GITHUB_SERVER_URL} || '';
    my $repo = $ENV{GITHUB_REPOSITORY} || '';
    return unless $url ne '' && $repo ne '';
    $url =~ s{/$}{};
    system 'git', 'remote', 'set-url', 'origin', "$url/$repo";
    return;
}

sub cmd_pack {
    my ($archive) = @_;
    my $dir = workspace();
    redact_git_remote();
    $archive = archive_path($archive);
    my ($exclude) = $archive =~ m{([^/]+)$};
    system('tar', '-czf', $archive, '--exclude', $exclude, '-C', $dir, '.') == 0
        or die "tar pack $archive failed\n";
    return $archive;
}

sub cmd_unpack {
    my ($archive) = @_;
    workspace();
    $archive = archive_path($archive);
    die "missing archive $archive\n" unless -f $archive;
    system('tar', '-xzf', $archive) == 0 or die "tar unpack $archive failed\n";
    return;
}

sub token {
    my $t = $ENV{ACTIONS_RUNTIME_TOKEN} || $ENV{GITHUB_TOKEN} || $ENV{GITEA_TOKEN} || '';
    die "missing job token for artifacts\n" if $t eq '';
    return $t;
}

sub server_base {
    my $base = $ENV{GITHUB_SERVER_URL} || '';
    die "missing GITHUB_SERVER_URL\n" if $base eq '';
    $base =~ s{/$}{};
    return $base;
}

sub run_id {
    my $id = $ENV{GITHUB_RUN_ID} || '';
    die "missing GITHUB_RUN_ID\n" if $id eq '';
    return $id;
}

sub artifacts_api {
    my $base = server_base();
    my $run  = run_id();
    return "$base/api/actions_pipeline/_apis/pipelines/workflows/$run/artifacts?api-version=6.0-preview";
}

sub abs_url {
    my ($url) = @_;
    return $url if $url =~ m{^https?://}i;
    my $base = server_base();
    $url = "/$url" unless $url =~ m{^/};
    return "$base$url";
}

sub urlenc {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord $1)/eg;
    return $s;
}

sub write_temp {
    my ($bytes) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    binmode $fh;
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub curl_ok {
    my (@args) = @_;
    my $has_out = grep { $_ eq '-o' } @args;
    unshift @args, '-o', '/dev/null' unless $has_out;
    my $status = system 'curl', '-fsS', @args;
    return $status == 0;
}

sub curl_body {
    my (@args) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;
    curl_ok('-o', $path, @args) or die "curl failed\n";
    open my $in, '<', $path or die "read $path: $!";
    binmode $in;
    local $/;
    my $data = <$in>;
    close $in;
    return defined $data ? $data : '';
}

sub auth_header {
    return 'Authorization: Bearer ' . token();
}

sub json_decode {
    my ($raw) = @_;
    return JSON::PP->new->utf8->decode($raw);
}

sub cmd_upload {
    token();
    workspace();
    my $archive = cmd_pack();
    my $size    = -s $archive;
    die "packed archive is empty\n" unless $size;

    open my $fh, '<', $archive or die "read $archive: $!";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    my $md5 = encode_base64(md5($bytes), '');

    my $api       = artifacts_api();
    my $body      = JSON::PP->new->utf8->encode({ Type => 'actions_storage', Name => $ARTIFACT });
    my $body_path = write_temp($body);
    my $created   = curl_body('-X', 'POST', '-H', auth_header(), '-H', 'Content-Type: application/json',
        '--data-binary', '@' . $body_path, $api,);
    my $upload = json_decode($created)->{fileContainerResourceUrl} || '';
    die "artifact upload URL missing\n" if $upload eq '';
    $upload = abs_url($upload);
    my $item = urlenc("$ARTIFACT/$TAR_NAME");
    my $end  = $size - 1;
    curl_ok(
        '-X',            'PUT', '-H', auth_header(), '-H', "x-tfs-filelength: $size",
        '-H',            "x-actions-results-md5: $md5",
        '-H',            "content-range: bytes 0-$end/$size",
        '--data-binary', '@' . $archive,
        "$upload?itemPath=$item",
    ) or die "artifact PUT failed\n";
    curl_ok('-X', 'PATCH', '-H', auth_header(), "$api&artifactName=" . urlenc($ARTIFACT),)
        or die "artifact confirm failed\n";
    return;
}

sub cmd_restore {
    workspace();
    my $api   = artifacts_api();
    my $list  = json_decode(curl_body('-H', auth_header(), $api));
    my ($art) = grep { ($_->{name} || '') eq $ARTIFACT } @{ $list->{value} || [] };
    die "prepared-tree artifact missing\n" unless $art;
    my $container = abs_url($art->{fileContainerResourceUrl} || '');
    die "artifact container URL missing\n" if $container eq '';
    my $files = json_decode(curl_body('-H', auth_header(), $container . '?itemPath=' . urlenc($ARTIFACT)));
    my $item  = $files->{value} && $files->{value}[0];
    my $url   = abs_url(($item && $item->{contentLocation}) || '');
    die "artifact download URL missing\n" if $url eq '';
    my $archive = archive_path();
    curl_ok('-H', auth_header(), '-o', $archive, $url) or die "artifact download failed\n";
    cmd_unpack($archive);
    return;
}
