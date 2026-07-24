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
instance_three="00000000-0000-4000-8000-000000000369"
instance_four="00000000-0000-4000-8000-000000000469"
instance_five="00000000-0000-4000-8000-000000000569"
instance_six="00000000-0000-4000-8000-000000000669"

if PGPASSWORD=wrong psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "wrong credential unexpectedly authenticated" >&2
  exit 1
fi

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_production.forbidden;" \
  >/dev/null 2>&1; then
  echo "node role unexpectedly accessed production" >&2
  exit 1
fi

if PGPASSWORD="$node_credential" \
  psql -X -q -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.nodes;" \
  >/dev/null 2>&1; then
  echo "node login unexpectedly bypassed authentication with SET ROLE" >&2
  exit 1
fi

psql_admin <<SQL
create function symphony_staging.test_delay_authentication()
returns trigger
language plpgsql
as \$\$
begin
  if new.node_instance_id = '$instance_three' then
    perform pg_sleep(4);
  end if;
  return new;
end
\$\$;
create trigger test_delay_authentication
before insert on symphony_staging.node_instance_history
for each row execute function symphony_staging.test_delay_authentication();
SQL

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_one');" \
  -c "select pg_advisory_unlock_all();" \
  -c "select pg_sleep(8);" \
  >/dev/null &
first_session_pid=$!
sleep 2

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null 2>&1; then
  echo "duplicate node session unexpectedly authenticated" >&2
  kill "$first_session_pid" 2>/dev/null || true
  exit 1
fi

wait "$first_session_pid"

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null 2>&1; then
  echo "disconnected backend implicitly retired its instance" >&2
  exit 1
fi

psql_admin -c \
  "select symphony_staging.retire_node_instance('$node_id', '$instance_one');" \
  >/dev/null

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_one');" \
  >/dev/null 2>&1; then
  echo "old node instance unexpectedly authenticated again" >&2
  exit 1
fi

psql_admin -c \
  "select symphony_staging.retire_node_instance('$node_id', '$instance_two');" \
  >/dev/null

if PGPASSWORD="$node_credential" \
  psql -X -q -d "postgresql://${login_role}@localhost:1/postgres" \
  -c "select 1" >/dev/null 2>&1; then
  echo "unreachable registry unexpectedly connected" >&2
  exit 1
fi

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_three');" \
  -c "select pg_sleep(8);" \
  -c "alter role current_user password 'disposable-old-session-choice';" \
  >/dev/null &
pre_rotation_session_pid=$!
sleep 2

rotation_started_at="$(date +%s)"
rotated="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.rotate_node_credential('$node_id');"
)"
rotation_elapsed="$(( $(date +%s) - rotation_started_at ))"
if [ "$rotation_elapsed" -lt 2 ]; then
  echo "rotation did not serialize with in-flight authentication" >&2
  exit 1
fi
psql_admin <<'SQL'
drop trigger test_delay_authentication
  on symphony_staging.node_instance_history;
drop function symphony_staging.test_delay_authentication();
SQL
IFS='|' read -r _rotated_node_id _rotated_role rotated_credential \
  credential_version rotated_contract_version <<<"$rotated"
unset rotated

test "$credential_version" = "2"
test "$rotated_contract_version" = "3"
test "$_rotated_role" != "$login_role"
rotated_node_url="postgresql://${_rotated_role}@localhost:5432/postgres"

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$rotated_node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_four');" \
  >/dev/null

wait "$pre_rotation_session_pid"

if PGPASSWORD="$node_credential" \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "rotated credential remained valid" >&2
  exit 1
fi

if PGPASSWORD=disposable-old-session-choice \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "retired login role reconnected after choosing its own password" >&2
  exit 1
fi
unset node_credential

psql_admin -c \
  "select symphony_staging.retire_node_instance('$node_id', '$instance_four');" \
  >/dev/null

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$rotated_node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_five');" \
  -c "select pg_sleep(4);" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_six');" \
  >/dev/null 2>&1 &
open_session_pid=$!
sleep 1

psql_admin -c "select symphony_staging.revoke_node('$node_id');" >/dev/null

if wait "$open_session_pid"; then
  echo "open session retained authentication after durable revocation" >&2
  exit 1
fi

if PGPASSWORD="$rotated_credential" \
  psql -X -q -d "$rotated_node_url" -c "select 1" >/dev/null 2>&1; then
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

psql_admin <<SQL
delete from symphony_staging.foundation_audit_events where node_id = '$node_id';
delete from symphony_staging.active_node_instances where node_id = '$node_id';
delete from symphony_staging.node_instance_history where node_id = '$node_id';
delete from symphony_staging.node_bindings where node_id = '$node_id';
delete from symphony_staging.node_login_principals where node_id = '$node_id';
delete from symphony_staging.nodes where node_id = '$node_id';
drop role "$login_role";
drop role "$_rotated_role";
SQL

psql_admin -c "
  update symphony_staging.contract_versions
  set contract_version = 4, migration_name = 'future-contract'
  where contract_name = 'node-identity-routing-foundation';
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted a future contract" >&2
  exit 1
fi
psql_admin -c "
  update symphony_staging.contract_versions
  set contract_version = 3,
      migration_name = '20260724010000_aro_169_node_enrollment'
  where contract_name = 'node-identity-routing-foundation';
" >/dev/null

psql_admin -c "alter table symphony_staging.active_node_instances rename to drifted_active_node_instances;" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted object drift" >&2
  exit 1
fi
psql_admin -c "alter table symphony_staging.drifted_active_node_instances rename to active_node_instances;" >/dev/null

if psql_admin \
  -c "begin; grant select on symphony_staging.active_node_instances to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted ACL drift" >&2
  exit 1
fi

psql_admin -c "
  select pg_advisory_lock(
    hashtextextended('aroak:symphony_staging:migrations', 0)
  );
  select pg_sleep(4);
" >/dev/null &
migration_lock_pid=$!
sleep 1
rollback_started_at="$(date +%s)"
psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql"
rollback_elapsed="$(( $(date +%s) - rollback_started_at ))"
wait "$migration_lock_pid"
if [ "$rollback_elapsed" -lt 2 ]; then
  echo "rollback did not serialize with concurrent contract DDL" >&2
  exit 1
fi

test "$(psql_admin -A -t -c "select contract_version from symphony_staging.contract_versions where contract_name = 'node-identity-routing-foundation';")" = "2"
psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

echo "ARO-169 disposable PostgreSQL lifecycle passed without printing credentials"
