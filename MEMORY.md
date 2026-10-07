# Memory

Operational facts for agents working in this Perl + Dancer2 repo. Decisions and their alternatives belong in `DECISIONS.md`. How to work belongs in `AGENTS.md`. Update a bullet when the fact changes. Do not put tokens, passwords, Tailscale hostnames, or home-directory paths here. The public local defaults (`postgres` / `postgres`, register token `dev`, port 4017) are the ones already published in `README.md`.

## Workspace

- Workspace root is this repository. The CMS remote is `github.com/brightball/carolina-codes`. Do not assume `../elixir` or `../perl` exists.
- Do not fold this tree into the CMS git remote. Do not query Ash tables.
- HTTP contract: CMS `priv/api/openapi.yaml` and `priv/api/AGENTS.md`. This repo has no `openapi.yaml`, `src/`, `db/*.sql`, or `tests/test_catalog.py`.
- Remotes used for this app are GitHub `origin` and the project Gitea remote. Do not deploy to Fly from a docs-only change.

## Runtime

- Image pin: `perl:5.40-slim` (`Dockerfile`). `GET /` reports `sprintf('%vd', $^V)`, which follows the process and can differ from 5.40.
- Framework floor in `cpanfile`: Dancer2 `>= 2.1.0`. Identity framework string is `Dancer2`. API version constant is `0.2.0`. `created_year` is 2026. `schema_version` is 1.
- Local listen port is 4017 (`bin/server` default). The image and `fly.toml` set `PORT=8080`.
- Listen host is `::` with `V6Only => 0`. If that bind fails, `bin/server` retries `0.0.0.0`.
- There is no Dancer2 `config.yml` and no generated `dancer2` app layout. Settings are `set` calls in `lib/CarolinaCodes/Dancer.pm` plus environment variables.
- Serializer is JSON, charset UTF-8. `show_errors`, `traces`, and `startup_info` are off. Sessions are off.
- Logger is `Console`, or `Null` when `HARNESS_ACTIVE` or `DANCER_TESTING` is set. Those two variables also skip registration.
- Views actually queried: `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`.
- One DBI handle is reused. Reconnect only after a failed query whose `ping` says the handle is dead. New DSNs get `connect_timeout=2` (libpq floors anything lower to 2). Default `sslmode` is `disable` unless the URL sets it.
- `GET /health` and `GET /` run no SQL.
- Registration forks from `app.psgi` via `start_register_with_elixir`. HTTP::Tiny timeout is 5 seconds. Failure is a warning, then the process still serves.

## Local run

- Install: `cpanm --local-lib=local --installdeps --with-develop .`
- Run: `perl -Ilocal/lib/perl5 bin/server` with `PORT=4017`.
- Live SQL needs Postgres 16 and `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev`.
- `CAROLINA_URL=http://127.0.0.1:4000` is optional. `POLYGLOT_REGISTER_TOKEN=dev` for local register. `PUBLIC_BASE_URL=http://127.0.0.1:4017`.
- `local/` is gitignored local::lib. `*.tdy` is gitignored. Do not commit either. Do not point Perl::Critic or perltidy at `local/`.

## Gates

- `make test` runs `t/handler.t` (fake catalog, no Postgres), `t/boot.t` (stalled CMS), `t/gate_wiring.t`, `t/ci_prepared_tree.t`, and `t/readme_versions.t`.
- The other gates are `make perlcritic`, `make audit` (`cpan-audit`, fail-closed), `make gitleaks`, and `make perltidy` (`--assert-tidy`). `make check` runs all five.
- `make hooks` runs `pre-commit install` and sets `core.hooksPath` to `.githooks`.
- Emergency skip: `SKIP=local-tests,perlcritic,cpan-audit,gitleaks,perltidy git commit`.
- gitleaks is mise pin 8.30.1 (`mise.toml`), not a CPAN module. Image `cpanm` does not install develop deps.
- CI is `.gitea/workflows/precommit.yml`: one prepare job, then five check jobs. The prepared-tree archive must be written outside the workspace. There is no `.github/workflows` copy of these gates.
- Tests are plain Perl scripts (`expect`, non-zero exit). They are not `Test::More`. `t/handler.t` stubs SQL with `QUERY_FN` and must not open Postgres.
