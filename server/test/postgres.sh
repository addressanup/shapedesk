#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SHAPEDESK_TEST_PG="$(mktemp -d /tmp/shapedesk-pg.XXXXXX)"
cleanup() {
  pg_ctl -D "$SHAPEDESK_TEST_PG/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$SHAPEDESK_TEST_PG"
}
trap cleanup EXIT
initdb -D "$SHAPEDESK_TEST_PG/data" --auth=trust --no-locale >/dev/null
pg_ctl -D "$SHAPEDESK_TEST_PG/data" -l "$SHAPEDESK_TEST_PG/postgres.log" \
  -o "-k $SHAPEDESK_TEST_PG -c listen_addresses=''" -w start >/dev/null
SHAPEDESK_TEST_DATABASE_URL="postgresql:///postgres?host=$SHAPEDESK_TEST_PG" npm test
