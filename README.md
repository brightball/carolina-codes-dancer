# carolina-codes-dancer

Read-only v1 polyglot API for Carolina Code Conference. Perl + **Dancer2** (PSGI/`plackup`), in honor of Jason Crome’s Dancer talk.

Queries PostgreSQL `v1_*` views. Registers with Elixir once on boot. Distinct from `../perl` (`HTTP::Daemon` on :4006).

```bash
cpanm --local-lib=local --installdeps .
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4017 \
PORT=4017 \
perl -Ilocal/lib/perl5 bin/server
```

`GET /` reports `language: "Perl"` and `framework: "Dancer2"`. `GET /health` returns `{"status":"ok"}` without touching Postgres.

```bash
perl -Ilocal/lib/perl5 t/handler.t
```
