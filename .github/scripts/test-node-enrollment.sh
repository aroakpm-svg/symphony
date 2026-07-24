#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
migrations_dir="$root_dir/elixir/priv/symphony_migrations"
admin_url="${TEST_DATABASE_URL:?TEST_DATABASE_URL is required}"

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -d "$admin_url" "$@"
}

psql_admin <<'SQL'
create schema extensions;
create extension pgcrypto with schema extensions;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema symphony_production;
SQL

psql_admin -f "$migrations_dir/20260723000000_aro_163_staging_foundation.sql"

psql_admin <<'SQL'
delete from symphony_staging.contract_versions
where contract_name like 'aro-163-created-role:%';
drop policy runtime_read_contract_versions
  on symphony_staging.contract_versions;
create policy runtime_read_contract_versions
  on symphony_staging.contract_versions
  for select
  to symphony_staging_runtime
  using (true);
drop policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
create policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);
alter role symphony_staging_runtime
  set search_path = pg_catalog, symphony_staging;
alter role symphony_staging_provisioner
  set search_path = pg_catalog, symphony_staging;
SQL

psql_admin -f "$migrations_dir/20260724000000_aro_168_staging_reconciliation.sql"
psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

provisioned="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.provision_node('disposable-node');"
)"
IFS='|' read -r node_id _binding_id login_role node_credential contract_version \
  <<<"$provisioned"
unset provisioned

test "$contract_version" = "3"
test -n "$node_id"
test -n "$login_role"
test -n "$node_credential"

node_url="postgresql://${login_role}@localhost:5432/postgres"
instance_one="00000000-0000-4000-8000-000000000169"
instance_two="00000000-0000-4000-8000-000000000269"

if PGPASSWORD=wrong psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "wrong credential unexpectedly authenticated" >&2
  exit 1
fi

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_production.forbidden;" \
  >/dev/null 2>&1; then
  echo "node role unexpectedly accessed production" >&2
  exit 1
fi

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.authenticate_node('$node_id', '$instance_one'); select pg_sleep(8);" \
  >/dev/null 2>&1 &
first_session_pid=$!
sleep 2

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null 2>&1; then
  echo "duplicate node session unexpectedly authenticated" >&2
  kill "$first_session_pid" 2>/dev/null || true
  exit 1
fi

wait "$first_session_pid"

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null

if PGPASSWORD="$node_credential" \
  psql -X -q -d "postgresql://${login_role}@localhost:1/postgres" \
  -c "select 1" >/dev/null 2>&1; then
  echo "unreachable registry unexpectedly connected" >&2
  exit 1
fi

rotated="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.rotate_node_credential('$node_id');"
)"
IFS='|' read -r _rotated_node_id _rotated_role rotated_credential \
  credential_version rotated_contract_version <<<"$rotated"
unset rotated

test "$credential_version" = "2"
test "$rotated_contract_version" = "3"

if PGPASSWORD="$node_credential" \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "rotated credential remained valid" >&2
  exit 1
fi
unset node_credential

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.authenticate_node('$node_id', '$instance_one');" \
  >/dev/null

psql_admin -c "select symphony_staging.revoke_node('$node_id');" >/dev/null

if PGPASSWORD="$rotated_credential" \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "revoked credential remained valid" >&2
  exit 1
fi
unset rotated_credential

if psql_admin -f \
  "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly orphaned a provisioned principal" >&2
  exit 1
fi

echo "ARO-169 disposable PostgreSQL lifecycle passed without printing credentials"
