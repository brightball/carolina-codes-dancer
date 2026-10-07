# carolina-codes-dancer

Read-only v1 polyglot API for Carolina Code Conference. Perl + **Dancer2** (PSGI, `bin/server`), in honor of Jason Crome’s Dancer talk.

Queries PostgreSQL `v1_*` views. Registers with Elixir once on boot, off the listen path, so a slow CMS cannot delay `/health`. Distinct from the HTTP::Daemon Perl API on port 4006.

## Versions

Language version is Perl 5.40, pinned by the runtime image `perl:5.40-slim` in the Dockerfile. `GET /` reports the running interpreter's `$^V`. A developer machine may print a different `perl -v`. Leave the image pin on 5.40.

Framework version is Dancer2 `>= 2.1.0`, the floor declared in `cpanfile`.

Runtime packages of note, also from `cpanfile`: Plack, DBI, DBD::Pg, HTTP::Tiny, and JSON::MaybeXS. That file also declares HTTP::Message, JSON, and URI.

Develop and tooling packages: Perl::Critic, Perl::Tidy, and CPAN::Audit, installed with `cpanm --with-develop`. gitleaks 8.30.1 is pinned in `mise.toml` and invoked by `make gitleaks`. It is not a CPAN module. The runtime image installs from the cpanfile and does not install the develop packages.

```bash
cpanm --local-lib=local --installdeps --with-develop .
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4017 \
PORT=4017 \
perl -Ilocal/lib/perl5 bin/server
```

`GET /` reports `language: "Perl"` and `framework: "Dancer2"`. `GET /health` returns `{"status":"ok"}` without touching Postgres.

```bash
make test        # t/handler.t, t/boot.t, t/gate_wiring.t, t/ci_prepared_tree.t, t/readme_versions.t
make perlcritic  # Perl::Critic on first-party Perl (not local/)
make audit       # cpan-audit of declared CPAN deps
make gitleaks    # gitleaks detect on the git tree
make perltidy    # perltidy --assert-tidy
make check       # all of the above
make hooks       # install local pre-commit hooks
```

Pre-commit runs the same five checks (`local tests`, `perlcritic`, `cpan-audit`, `gitleaks`, `perltidy`). Install once with `make hooks` (needs `pre-commit` on PATH; `gitleaks` from mise or PATH). Emergency skip: `SKIP=local-tests,perlcritic,cpan-audit,gitleaks,perltidy git commit`.

Gitea Actions (`.gitea/workflows/precommit.yml`) prepares the tree once (token clone, OS packages, `cpanm --with-develop`, gitleaks), then runs those five Make targets as separate jobs against the restored tree.

```bash
perl -Ilocal/lib/perl5 t/handler.t
```
