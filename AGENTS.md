# carolina-codes-dancer

Instructions for this read-only HTTP API. The Carolina Code Conference Elixir site can rotate onto it. The implementation is Perl and Dancer2 on PSGI.

This repository is one finished sibling in the polyglot fleet. It is the workspace root. The Phoenix CMS is a different remote (`github.com/brightball/carolina-codes`). Do not assume a sibling checkout (`../elixir`, `../perl`, or any other) is present. Do not fold this tree into the CMS git remote.

The forkable starter (`carolina-codes-api-starter`) ships its own contract, a Compose catalog, and a replaceable runtime. This tree does not. The source of truth for routes and payloads is the CMS contract: `priv/api/openapi.yaml` and `priv/api/AGENTS.md`. Responses are ordinary JSON through Dancer2's JSON serializer. Ash JSON:API (`application/vnd.api+json`) is out of bounds.

Before an architectural change, read `DECISIONS.md` and `MEMORY.md`. `DECISIONS.md` is the append-only ledger: add a dated entry with status, alternatives, and reasoning. Do not rewrite or delete an accepted entry; supersede it with a new one. `MEMORY.md` is the short list of operational facts. A CPAN `Changes` file is a release changelog and is not a substitute for `DECISIONS.md`.

## Purpose

The Phoenix app (`Carolina.Polyglot`) keeps at most one language API warm and reads speakers and sponsors from it. With no APIs registered, it falls back to Ash. This process must:

1. Query PostgreSQL **v1 views** only. Never query Ash resource tables or other base tables.
2. Expose the routes below. Payload shape follows the CMS OpenAPI contract.
3. **Register once on boot**, off the listen path. No heartbeat. If `CAROLINA_URL` is unset or the CMS is down, log and keep serving.

## Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | SQL views |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | Elixir site. Optional. Register no-ops if unset or down |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer token for register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4017` | URL Elixir will call |
| `PORT` | `4017` | Listen port. The image and Fly set `8080` |

`GET /health` does not need the database. Handler tests use a fake catalog and do not need Postgres. Live HTTP against the views needs Postgres 16 (the CMS database) and `DATABASE_URL`. This repo does not ship a Compose Postgres service. The starter's Postgres 18 catalog is not the database this process uses.

## SQL views (query these)

`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`.

The views live in the CMS database. There is no `db/*.sql` in this repo.

Year-scoped speaker rows include `languages` and `topics` taken from that year's `v1_talks`. Year-scoped sponsor rows come from `v1_year_sponsors` and include `tier` and `blurb`.

Do not `SELECT` from `speakers`, `organizations`, `talks`, or other Ash or base tables. The views are the API. There are no writes.

## Required HTTP routes

Wrap list payloads as `{ "data": [ ... ] }`. Unknown slugs return 404 `{ "error": "not_found" }`.

- `GET /health` — `{ "status": "ok" }`. Does not open Postgres.
- `GET /` — identity: `language` (`Perl`), `framework` (`Dancer2`), `language_version`, `api_version`, `created_year`, `schema_version`, `endpoints`
- `GET /v1/years`
- `GET /v1/speakers` and `GET /v1/speakers?year=2025`
- `GET /v1/speakers/{slug}` and `GET /v1/speakers/{year}/{slug}`
- `GET /v1/sponsors` and `GET /v1/sponsors?year=2025`
- `GET /v1/sponsors/{slug}` and `GET /v1/sponsors/{year}/{slug}`

`photo_path` and `logo_path` are web paths. Return the path. This process does not serve image bytes.

`language_version` is `sprintf('%vd', $^V)` of the running process. The supported pin is the image, Perl 5.40 (`perl:5.40-slim`). A developer machine may run a different Perl. Do not retag the image to match `perl -v`.

Every response sets `X-Polyglot-Language: Perl` and `X-Polyglot-Framework: Dancer2`.

## Register on boot (once)

`POST {CAROLINA_URL}/internal/api-endpoints/register`

```
Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}
Content-Type: application/json
```

`app.psgi` calls `start_register_with_elixir` unless `HARNESS_ACTIVE` or `DANCER_TESTING` is set. That forks the POST so a stalled CMS cannot delay the listener. The parent records the attempt and does not wait. If fork fails, registration runs in-process and still must not prevent serving.

Body fields: `language`, `language_version`, `api_version`, `framework`, `created_year`, `base_url` (`PUBLIC_BASE_URL`, otherwise `http://127.0.0.1:$PORT`), `schema_version` (1), and `endpoints`. `endpoints` is the same table `GET /` returns: objects with `method`, `path`, and `query`.

Do not heartbeat. Elixir keep-alives the warm API. If `CAROLINA_URL` or the token is empty, skip the call. If the POST fails (connection refused, timeout, 4xx, 5xx), log and keep serving.

## Commands

```bash
cpanm --local-lib=local --installdeps --with-develop .
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4017 \
PORT=4017 \
perl -Ilocal/lib/perl5 bin/server
```

`local/` is the gitignored local::lib. Perl::Critic and perltidy see first-party Perl only (`app.psgi`, `bin/server`, `lib/`, `t/*.t`, `scripts/*.pl`).

```bash
make test        # t/handler.t (fake catalog, no Postgres), t/boot.t (stalled CMS registration), t/gate_wiring.t, t/ci_prepared_tree.t, t/readme_versions.t
make perlcritic  # Perl::Critic --profile .perlcriticrc
make audit       # cpan-audit of declared CPAN deps (fail-closed)
make gitleaks    # gitleaks detect on the git tree
make perltidy    # perltidy --profile=.perltidyrc --assert-tidy
make check       # all five gates
make hooks       # pre-commit install, then core.hooksPath .githooks
```

The five gates are `test`, `perlcritic`, `audit`, `gitleaks`, and `perltidy`. Pre-commit runs those five checks. Install once with `make hooks` (`pre-commit` on `PATH`; `gitleaks` from mise or `PATH`). Emergency skip: `SKIP=local-tests,perlcritic,cpan-audit,gitleaks,perltidy git commit`.

Gitea Actions (`.gitea/workflows/precommit.yml`) prepares the tree once (token clone, OS packages, `cpanm --with-develop`, gitleaks), then runs the five Make targets as separate jobs against the restored tree. The prepared-tree archive stays outside the workspace. There is no GitHub Actions workflow for these gates.

## Layout

| Path | Role |
| --- | --- |
| `app.psgi` | Start registration off the listen path, then return `to_app` |
| `bin/server` | Dual-stack PSGI listener. Binds `::`, falls back to `0.0.0.0` |
| `lib/CarolinaCodes/Dancer.pm` | Routes, `v1_*` queries, registration |
| `cpanfile` | Runtime dependencies and develop tools |
| `t/*.t` | Plain-Perl tests. Fake catalog. No Postgres |
| `Makefile` | `test`, `perlcritic`, `audit`, `gitleaks`, `perltidy`, `check`, `hooks` |
| `Dockerfile` | `perl:5.40-slim`. Runtime deps from the cpanfile. Develop deps stay out of the image |
| `fly.toml` | Fly app. Behavior changes are out of scope for a docs-only task |
| `mise.toml` | gitleaks pin |
| `scripts/ci-prepared-tree.pl` | CI archive upload and restore |
| `DECISIONS.md` | Append-only decision ledger |
| `MEMORY.md` | Operational facts |
| `AGENTS.md` | This file |

Starter-only paths are not part of this tree. Do not add `openapi.yaml`, `src/`, `db/*.sql`, or `tests/test_catalog.py`.

Do not commit `local/` or `*.tdy`.

## Checklist

- Contract paths return 200 with example-shaped JSON, and 404 on an unknown slug
- `?year=` speaker rows include `languages` and `topics`; year-scoped sponsor rows include `tier`
- Register runs once at process start, off the listen path, and no-ops if the CMS is down or unset
- No writes and no Ash table names
- `GET /health` does not use the database
- Architectural changes append a `DECISIONS.md` entry instead of rewriting history
- `DECISIONS.md` and `MEMORY.md` were read first
