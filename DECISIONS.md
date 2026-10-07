# Decisions

Append-only ledger for this Perl + Dancer2 application.

Perl distributions often keep a CPAN `Changes` file (the CPAN::Changes format) as a release changelog. That file records what shipped. It does not record alternatives or why a design was chosen, and old entries get edited. This repository is an application, not a CPAN distribution, so a `Changes` file is not the decision log.

Ratified choices live here, one dated entry each, with status, alternatives, and reasoning. This is the single-file form of an architecture decision record: easier for an agent to read than a `docs/adr/` tree, and append-only so history stays intact. Operating instructions live in `AGENTS.md`. Short facts that are not decisions live in `MEMORY.md`.

Read this file before an architectural change. Add a new entry to supersede an old one. Do not rewrite an accepted entry in place.

## 2026-09-05 — Dancer2 on PSGI, separate from the HTTP::Daemon API

- **Status:** accepted
- **Alternatives:** extend the HTTP::Daemon Perl API (port 4006); serve the contract from a raw Plack app with no framework.
- **Reasoning:** Commit `4319fb3` added this process as a Perl + Dancer2/PSGI sibling, explicitly not HTTP::Daemon, on port 4017. The README records the tribute to Jason Crome's Dancer talk. `CarolinaCodes::Dancer->to_app` returns a PSGI coderef, and `t/handler.t` drives that coderef through Plack::Test. The same test reads `lib/CarolinaCodes/Dancer.pm` and requires `use Dancer2` while rejecting `HTTP::Daemon`. Identity reports `language: Perl` and `framework: Dancer2`.

## 2026-09-05 — Query `v1_*` views and return ordinary JSON

- **Status:** accepted
- **Alternatives:** `SELECT` from Ash resource tables; implement Ash JSON:API (`application/vnd.api+json`); vendor the starter's `db/*.sql` catalog into this repo.
- **Reasoning:** Every catalog query in `lib/CarolinaCodes/Dancer.pm` reads `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, or `v1_year_sponsors`. List routes wrap rows as `{ "data": [ ... ] }`. Dancer2's JSON serializer writes the body. `t/handler.t` feeds a fake catalog through `QUERY_FN` and checks those view names, year-scoped `languages` / `topics`, and sponsor `tier`. The 2026-09-06 `AGENTS.md` states that the views live in the CMS database and that Ash tables are out of bounds. This repo has no `db/` tree.

## 2026-09-05 — One endpoint table for identity and registration

- **Status:** accepted
- **Alternatives:** a second list of `"GET /path"` strings, matching the starter's register example, kept separate from `GET /`.
- **Reasoning:** `identity` and `register_payload` both publish `@ENDPOINTS` (method, path, query). One table means the document Elixir receives cannot drift from `GET /`. The register POST still carries `language`, `language_version`, `api_version`, `framework`, `created_year`, `base_url`, and `schema_version` 1.

## 2026-09-05 — Perl 5.40 image pin

- **Status:** accepted
- **Alternatives:** a floating `perl:slim` tag; whatever `perl` is on a developer machine; pinning the image to the host interpreter.
- **Reasoning:** `Dockerfile` has been `FROM perl:5.40-slim` since `4319fb3`. `LANGUAGE_VERSION` in the app is `sprintf('%vd', $^V)` at runtime, so `GET /` follows the process, which can be newer than 5.40 on a workstation. The supported language version is the image pin. Develop tooling is not a reason to retag the image.

## 2026-09-05 — Custom dual-stack listener, with an IPv4 fallback from 2026-09-22

- **Status:** accepted
- **Alternatives:** stock `plackup` (its `HTTP::Server::PSGI` uses `IO::Socket::INET`, which rejects host `::`); bind `0.0.0.0` only; fail the process when `::` returns `EINVAL`.
- **Reasoning:** `bin/server` subclasses `HTTP::Server::PSGI` and listens with `IO::Socket::IP`. `listen_host` is `::` with `V6Only => 0`, so one socket accepts IPv4 and IPv6 where the stack allows it. Commit `2ea1f6b` added the fallback: rootless Docker rejects `::`, Fly has IPv6, and the process retries `0.0.0.0` instead of exiting. `t/handler.t` locks `listen_host` to `::`.

## 2026-09-22 — Register once, off the listen path

- **Status:** accepted
- **Alternatives:** call `register_with_elixir` inline before `to_app` (the `4319fb3` shape), which blocks startup on the CMS; a heartbeat loop after listen.
- **Reasoning:** Commit `2ea1f6b` moved registration off the listen path so a slow CMS cannot delay `/health`. `app.psgi` calls `start_register_with_elixir`, which forks, and the parent does not wait. The child uses `HTTP::Tiny` with a 5 second timeout against `/internal/api-endpoints/register`. An empty `CAROLINA_URL` or token skips the call. A failed POST is logged and the process keeps serving. `$REGISTERED` makes the attempt once. There is no heartbeat; Elixir keep-alives the warm API. `t/boot.t` covers a stalled CMS. `HARNESS_ACTIVE` and `DANCER_TESTING` skip the fork so the suite does not register.

## 2026-09-22 — One catalog connection and a 2 second connect timeout

- **Status:** accepted
- **Alternatives:** connect on every request; no `connect_timeout` (a down database hangs the request); a timeout below 2 seconds.
- **Reasoning:** Commit `2ea1f6b` reuses one DBI handle. A failed query pings that handle and reconnects only when the connection is dead, so bad SQL does not masquerade as a dropped socket. `apply_connect_timeout` sets `connect_timeout=2` unless the DSN already has one. The comment in `Dancer.pm` records that libpq treats a value below 2 as 2, and that 2 seconds still fails inside the 3 second bound `t/handler.t` enforces. Default `sslmode` is `disable` unless the URL sets `sslmode`.

## 2026-09-22 — Five separate quality gates

- **Status:** accepted
- **Alternatives:** one `make check` job; one `pre-commit run` job; GitHub Actions `actions/checkout` per check; installing CPAN modules again inside each check.
- **Reasoning:** `Makefile` targets are `test`, `perlcritic`, `audit`, `gitleaks`, and `perltidy`. `make check` runs all five. `.pre-commit-config.yaml` maps one hook to each target. `.gitea/workflows/precommit.yml` has `prepare-stage` plus one job per check. `t/gate_wiring.t` locks the hook ids, the job names, fail-closed `cpan-audit` (no `--exit-zero`), and that critic and tidy are not aimed at `local/`. Develop requirements `Perl::Critic`, `Perl::Tidy`, and `CPAN::Audit` come from `cpanfile`. gitleaks is the mise tool, not a CPAN module. The image install is `cpanm --notest --installdeps .` with no `--with-develop`, which `t/handler.t` reads off the Dockerfile. Commit `2ea1f6b` replaced the earlier hardcoded `cpanm` module list with that cpanfile install.

## 2026-09-22 — Prepared-tree archive stays outside the workspace

- **Status:** accepted
- **Alternatives:** `git init` or `actions/checkout` in every job; write the tar inside the job workspace.
- **Reasoning:** Gitea points `TMPDIR` at the job directory. Commit `07d8e80` records that `tar` was packing the archive it was still writing, so prepare-stage failed. `scripts/ci-prepared-tree.pl` keeps that archive outside the workspace. Check jobs restore the prepared tree and do not run `cpanm` or `apt-get` themselves (`t/gate_wiring.t`).

## 2026-09-06 — This repo is the workspace root; the contract stays in the CMS

- **Status:** accepted
- **Alternatives:** treat the CMS checkout as the workspace; copy `openapi.yaml` and the starter SQL into this tree; assume `../elixir` exists.
- **Reasoning:** Commit `8e62b11` added the cloud notes: this remote is the workspace root, the CMS is `github.com/brightball/carolina-codes`, and sibling directories are not guaranteed. The same note sets the contract at CMS `priv/api/openapi.yaml` and `priv/api/AGENTS.md`, forbids folding this tree into the CMS remote, and documents Postgres 16 for live HTTP. The starter's local `openapi.yaml`, `src/`, `db/*.sql`, and `tests/test_catalog.py` are not how this API is built.

## 2026-09-22 — Fly suspends idle machines

- **Status:** accepted
- **Alternatives:** `auto_stop_machines = "stop"` (cold boot on the next request); `min_machines_running = 1` (always on).
- **Reasoning:** Commit `2ea1f6b` switched idle machines to `suspend` so the next request resumes instead of booting. `fly.toml` sets `auto_stop_machines = "suspend"`, `auto_start_machines = true`, and `min_machines_running = 0`. The HTTP check is `GET /health`. `t/handler.t` locks suspend, autostart, scale-to-zero, and a memory cap. The VM is 256 MB shared CPU. Docs work must not change this behavior.
