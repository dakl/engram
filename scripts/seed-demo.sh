#!/usr/bin/env bash
# Seed a throwaway demo store with believable memories for screenshots / demos.
# Points engram at $1 (default /tmp/engram-demo.sqlite) via the ENGRAM_DB override
# (EngramPaths.defaultDatabaseURL) — never touches the real store.
#
#   bash scripts/seed-demo.sh [db-path]
#   ENGRAM_DB=/tmp/engram-demo.sqlite open -n /path/to/Engram.app   # launch app on it
set -euo pipefail

DB="${1:-/tmp/engram-demo.sqlite}"
ENGRAM="${ENGRAM:-engram}"

rm -f "$DB" "$DB-wal" "$DB-shm"
echo "seeding $DB …"

m() { ENGRAM_DB="$DB" "$ENGRAM" store "$1" --title "$2" --tags "$3" --source "$4" >/dev/null; }

m 'We chose Postgres over DynamoDB for orbit-api because the access patterns are relational and we need ad-hoc queries during incidents.' \
  'orbit-api: Postgres over DynamoDB' 'type:decision,language:go,postgres,database' orbit-api
m 'orbit-api health checks must run on a separate port from the main API, or the load balancer drains the instance during long GC pauses.' \
  'orbit-api: health check on a separate port' 'type:fact,language:go,gotcha,infra' orbit-api
m 'Daniel prefers small, focused PRs that merge within a day over large long-lived feature branches.' \
  'Prefer small, fast-merging PRs' 'type:preference,workflow,pr' notes
m 'mobile-app runs React Native 0.74 with the new Fabric architecture enabled; legacy native modules go through the interop layer.' \
  'mobile-app: React Native 0.74 + Fabric' 'type:fact,language:typescript,mobile' mobile-app
m 'Run pricing-service locally with make up (starts Postgres and Redis), then uv run pricing serve --reload.' \
  'pricing-service: run locally' 'type:howto,language:python,postgres' pricing-service
m 'We deploy from the release branch via GitHub Actions; main is always shippable and tags trigger production rollouts.' \
  'Deploy from the release branch' 'type:decision,ci,release,infra' infra
m 'pricing-service uses bankers rounding (half-to-even) for tax. Do not change it to round-half-up; finance depends on it.' \
  'pricing-service: bankers rounding is intentional' 'type:fact,language:python,gotcha,finance' pricing-service
m 'NLContextualEmbedding assets download once on-device; until then recall falls back to a weaker static embedder.' \
  'Embeddings download on first run' 'type:fact,language:swift,embeddings' notes
m 'Priya owns the auth domain. Ping her before changing token TTLs or the refresh flow.' \
  'Priya owns the auth domain' 'type:person,auth,team' notes
m 'On-call runbook: dashboards live in Grafana under Orbit Overview; alerts route to the orbit-oncall channel.' \
  'On-call runbook' 'type:reference,infra,oncall' infra
m 'Adopted optimistic concurrency (a version column plus 409 on mismatch) for editable timeline rows; skipped the edit-log until real-time collaboration is needed.' \
  'OCC for editable timeline rows' 'type:decision,language:typescript,database' mobile-app
m 'Go builds return 401 from the private artifact registry when the netrc token is stale. Run make setup to refresh, then rebuild without the cache.' \
  'Stale netrc breaks Go builds (401)' 'type:fact,language:go,gotcha,ci' infra
m 'Use uv for everything Python: uv add, uv run, uv sync. Never pip or a plain venv.' \
  'Use uv, not pip' 'type:preference,language:python,tooling' notes
m 'orbit-api publishes domain events to Pub/Sub via an outbox table; all consumers must be idempotent.' \
  'orbit-api: outbox to Pub/Sub' 'type:fact,language:go,events,database' orbit-api
m 'Cut a release with make release-patch: it gates on a clean pushed tree, bumps the version, tags, and pushes; CI then notarizes.' \
  'Cut a release with make release-patch' 'type:howto,release,ci' notes
m 'Memory stays local-first with no account. Sync will use Apple iCloud later, with no third-party backend.' \
  'Local-first, iCloud sync planned' 'type:decision,sync,roadmap' notes
m 'Do not use 100vh in the embedded webview; iOS reports a stale viewport on rotation. Use the visualViewport API instead.' \
  'mobile-app: avoid 100vh in the webview' 'type:fact,language:typescript,mobile,gotcha' mobile-app
m 'pricing-service audit table is partitioned by month with 90-day retention; older partitions drop automatically.' \
  'pricing-service: 90-day audit retention' 'type:fact,language:python,postgres,database' pricing-service

COUNT=$(ENGRAM_DB="$DB" "$ENGRAM" list --json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?")
echo "done — $COUNT memories in $DB"