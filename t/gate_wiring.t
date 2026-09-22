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

my $precommit = slurp('.pre-commit-config.yaml');
my $workflow  = slurp('.gitea/workflows/precommit.yml');
my $makefile  = slurp('Makefile');
my $hook      = slurp('.githooks/pre-commit');

my @hook_ids = $precommit =~ /^\s+- id:\s*(\S+)/mg;
expect(scalar(@hook_ids) == 5, 'pre-commit defines five separate hooks');
expect(
    (join ',', @hook_ids) eq 'local-tests,perlcritic,cpan-audit,gitleaks,perltidy',
    'pre-commit hook ids are local-tests, perlcritic, cpan-audit, gitleaks, perltidy'
);
expect($precommit =~ /SKIP=local-tests,perlcritic,cpan-audit,gitleaks,perltidy/,
    'pre-commit documents an explicit SKIP escape');
expect($precommit =~ /entry:\s*make test/,       'local-tests hook runs make test');
expect($precommit =~ /entry:\s*make perlcritic/, 'perlcritic hook runs make perlcritic');
expect($precommit =~ /entry:\s*make audit/,      'cpan-audit hook runs make audit');
expect($precommit =~ /entry:\s*make gitleaks/,   'gitleaks hook runs make gitleaks');
expect($precommit =~ /entry:\s*make perltidy/,   'perltidy hook runs make perltidy');

expect($hook =~ /pre-commit run/,  'githook prefers the pre-commit runner');
expect($hook =~ /make test/,       'githook fallback runs tests');
expect($hook =~ /make perlcritic/, 'githook fallback runs perlcritic');
expect($hook =~ /make audit/,      'githook fallback runs cpan-audit');
expect($hook =~ /make gitleaks/,   'githook fallback runs gitleaks');
expect($hook =~ /make perltidy/,   'githook fallback runs perltidy');

expect(
    $makefile =~ /^\s*perl\s+-Ilocal\/lib\/perl5\s+t\/handler\.t/m,
    'make test runs t/handler.t against the shipped app'
);
expect($makefile =~ /^\s*perl\s+-Ilocal\/lib\/perl5\s+t\/boot\.t/m, 'make test runs the stalled-registration boot');
expect($makefile =~ /t\/ci_prepared_tree\.t/,                       'make test runs the prepared-tree helper test');
expect($makefile =~ /perlcritic\s+--profile/,                       'make perlcritic invokes perlcritic');
expect($makefile =~ /cpan-audit\b/,                                 'make audit invokes cpan-audit');
expect($makefile !~ /--exit-zero/,                                  'cpan-audit is fail-closed');
expect($makefile =~ /gitleaks\s+detect/,                            'make gitleaks invokes gitleaks detect');
expect($makefile =~ /perltidy\s+.*--assert-tidy/s,                  'make perltidy invokes perltidy --assert-tidy');
expect($makefile !~ m{perlcritic.*local/},                          'perlcritic is not aimed at local/');
expect($makefile =~ /wildcard lib\/\*\.pm.*t\/\*\.t/,               'critic/tidy sources are first-party Perl only');

my ($jobs_block) = $workflow =~ /^jobs:\s*\n(.*)\z/ms;
$jobs_block = $jobs_block // '';
my @job_names = $jobs_block =~ /^  ([A-Za-z0-9_-]+):/mg;
expect(scalar(@job_names) == 6, 'Gitea workflow has a prepare-stage job plus one job per check');
expect((join ',', @job_names) eq 'prepare-stage,test,perlcritic,cpan-audit,gitleaks,perltidy',
    'Gitea job names are prepare-stage, then the five checks');
expect($workflow !~ /^\s*- run:\s*make check\s*$/m,        'Gitea is not a single combined make check job');
expect($workflow !~ /^\s*- run:\s*pre-commit run/m,        'Gitea is not a single combined pre-commit job');
expect($workflow !~ /^\s*git init\b/m,                     'Gitea workflow does not git init');
expect($workflow !~ /^\s+-?\s*uses:\s*actions\/checkout/m, 'Gitea workflow does not use actions/checkout');
expect($workflow =~ /x-access-token:\$\{token\}/,          'Gitea clones GITHUB_SHA with the job token');
expect($workflow =~ /missing job token for git fetch/,     'Gitea fails closed if the job token is missing');

my %jobs;
while ($jobs_block =~ /^  ([A-Za-z0-9_-]+):\n([\s\S]*?)(?=^  [A-Za-z0-9_-]+:|\z)/mg) {
    $jobs{$1} = $2;
}

my $prepare = $jobs{'prepare-stage'} // '';
expect($prepare =~ /x-access-token:\$\{token\}/, 'prepare-stage clones GITHUB_SHA with the job token');
expect($prepare =~ /git fetch --depth 1 origin "\$\{GITHUB_SHA\}"/, 'prepare-stage fetches GITHUB_SHA');
expect($prepare =~ /apt-get/,                                       'prepare-stage installs shared OS packages');
expect($prepare =~ /cpanm .*--with-develop/, 'prepare-stage installs CPAN runtime plus develop deps');
expect($prepare =~ /Perl::Critic|Perl::Tidy|CPAN::Audit|--with-develop/,
    'prepare-stage installs Perl::Critic, Perl::Tidy, and CPAN::Audit via develop deps');
expect($prepare =~ /gitleaks_8\.30\.1_linux_x64\.tar\.gz/, 'prepare-stage installs gitleaks');
expect($prepare =~ /ci-prepared-tree\.pl upload/,          'prepare-stage persists the prepared tree');
expect($prepare !~ /^\s+needs:/m,                          'prepare-stage does not depend on a check job');

expect(($jobs{test}         // '') =~ /^\s+- run:\s*make test\s*$/m,       'test job runs make test');
expect(($jobs{perlcritic}   // '') =~ /^\s+- run:\s*make perlcritic\s*$/m, 'perlcritic job runs make perlcritic');
expect(($jobs{'cpan-audit'} // '') =~ /^\s+- run:\s*make audit\s*$/m,      'cpan-audit job runs make audit');
expect(($jobs{gitleaks}     // '') =~ /^\s+- run:\s*make gitleaks\s*$/m,   'gitleaks job runs make gitleaks');
expect(($jobs{perltidy}     // '') =~ /^\s+- run:\s*make perltidy\s*$/m,   'perltidy job runs make perltidy');

my @checks = qw(test perlcritic cpan-audit gitleaks perltidy);
for my $name (@checks) {
    my $body = $jobs{$name} // '';
    expect($body =~ /^\s+needs:\s*\[prepare-stage\]\s*$/m, "$name needs prepare-stage");
    expect($body =~ /ci-prepared-tree\.pl restore/,        "$name restores the prepared tree");
    expect($body !~ /cpanm/,                               "$name does not run cpanm");
    expect($body !~ /apt-get/,                             "$name does not apt-get");
    expect($body !~ /gitleaks_.*\.tar\.gz/,                "$name does not download gitleaks");
    expect($body !~ /git clone/,                           "$name does not clone");
    expect($body !~ /git fetch/,                           "$name does not git fetch");
    expect($body =~ /missing job token for restore/,       "$name fails closed without a restore token");

    for my $other (@checks) {
        next if $other eq $name;
        expect($body !~ /needs:.*\b\Q$other\E\b/, "$name does not needs $other");
    }
}

expect(!-e "$root/.github/workflows/precommit.yml", 'parallel jobs live in .gitea/workflows, not GitHub Actions');

if ($failed) {
    warn "gate wiring tests failed\n";
    exit 1;
}
warn "gate wiring tests passed\n";
exit 0;
