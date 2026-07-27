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

psql_admin <<'SQL'
create role aro169_v2_drift_writer nologin noinherit;
grant update on symphony_staging.nodes to aro169_v2_drift_writer;
grant aro169_v2_drift_writer to symphony_staging_provisioner
  with inherit true, set false;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted v2 authorization state" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin <<'SQL'
revoke aro169_v2_drift_writer from symphony_staging_provisioner;
revoke update on symphony_staging.nodes from aro169_v2_drift_writer;
drop role aro169_v2_drift_writer;
SQL

psql_admin -c "
  revoke select (node_id) on symphony_staging.nodes
    from symphony_staging_runtime;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted v2 column ACL drift" >&2
  exit 1
fi
psql_admin -c "
  grant select (node_id) on symphony_staging.nodes
    to symphony_staging_runtime;
" >/dev/null

psql_admin -c "
  grant select on symphony_staging.nodes to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unrelated-role ACL drift" >&2
  exit 1
fi
psql_admin -c "
  revoke select on symphony_staging.nodes from service_role;
" >/dev/null

psql_admin -c "
  alter default privileges in schema symphony_staging
    grant select on tables to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted default ACL drift" >&2
  exit 1
fi
psql_admin -c "
  alter default privileges in schema symphony_staging
    revoke select on tables from service_role;
" >/dev/null

psql_admin <<'SQL'
create role aro169_unlisted_role nologin;
alter default privileges in schema symphony_staging
  grant select on tables to aro169_unlisted_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unlisted-role default ACL drift" >&2
  exit 1
fi
psql_admin <<'SQL'
alter default privileges in schema symphony_staging
  revoke select on tables from aro169_unlisted_role;
grant usage on schema symphony_staging to aro169_unlisted_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unlisted schema ACL drift" >&2
  exit 1
fi
psql_admin <<'SQL'
revoke usage on schema symphony_staging from aro169_unlisted_role;
alter table symphony_staging.nodes disable trigger enforce_node_transition;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted disabled foundation trigger" >&2
  exit 1
fi
psql_admin <<'SQL'
alter table symphony_staging.nodes enable trigger enforce_node_transition;
create table symphony_staging.aro169_unexpected_v2_object(id integer);
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted extra staging object" >&2
  exit 1
fi
psql_admin <<'SQL'
drop table symphony_staging.aro169_unexpected_v2_object;
drop role aro169_unlisted_role;
SQL

psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

provisioned="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.provision_node(
      '16900000-0000-4000-8000-000000000001',
      'disposable-node',
      'ARO-169-disposable',
      'exclusive'
    );"
)"
IFS='|' read -r node_id _binding_id login_role node_credential contract_version credential_returned \
  <<<"$provisioned"
unset provisioned

test "$contract_version" = "3"
test "$credential_returned" = "t"
test -n "$node_id"
test -n "$login_role"
test -n "$node_credential"
test "$(psql_admin -A -t -c "select target_node_id = '$node_id' and routing_policy = 'exclusive' from symphony_staging.routing_assignments where issue_id = 'ARO-169-disposable';")" = "t"

replayed="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.provision_node(
      '16900000-0000-4000-8000-000000000001',
      'disposable-node',
      'ARO-169-disposable',
      'exclusive'
    );"
)"
IFS='|' read -r replayed_node_id _ _ replayed_credential _ replayed_secret \
  <<<"$replayed"
unset replayed
test "$replayed_node_id" = "$node_id"
test -z "$replayed_credential"
test "$replayed_secret" = "f"

if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000001',
  'different-request',
  'ARO-169-disposable',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "operation ID unexpectedly accepted a different request" >&2
  exit 1
fi

psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000004',
  E'fingerprint-a\\nfingerprint-b',
  'fingerprint-c',
  'exclusive'
);" >/dev/null
if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000004',
  'fingerprint-a',
  E'fingerprint-b\\nfingerprint-c',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "structured operation fingerprint accepted a newline-boundary collision" >&2
  exit 1
fi
psql_admin <<'SQL'
select node_id as node_id
from symphony_staging.node_lifecycle_operations
where operation_id = '16900000-0000-4000-8000-000000000004'
\gset collision_
select format(
  'revoke execute on function symphony_staging.authenticate_node(uuid, uuid) from %I',
  login_role
)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
select format('revoke usage on schema symphony_staging from %I', login_role)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
select format('drop role %I', login_role)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
delete from symphony_staging.foundation_audit_events
where node_id = :'collision_node_id';
delete from symphony_staging.routing_assignments
where issue_id = E'fingerprint-c';
delete from symphony_staging.node_lifecycle_operations
where operation_id = '16900000-0000-4000-8000-000000000004';
delete from symphony_staging.node_bindings
where node_id = :'collision_node_id';
delete from symphony_staging.node_login_principals
where node_id = :'collision_node_id';
delete from symphony_staging.node_principal_history
where node_id = :'collision_node_id';
delete from symphony_staging.nodes
where node_id = :'collision_node_id';
SQL

for _attempt in 1 2; do
  psql_admin -c "select * from symphony_staging.provision_node(
    '16900000-0000-4000-8000-000000000002',
    'concurrent-node',
    'ARO-169-concurrent',
    'exclusive'
  );" >/dev/null &
done
wait
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_lifecycle_operations where operation_id = '16900000-0000-4000-8000-000000000002';")" = "1"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.routing_assignments where issue_id = 'ARO-169-concurrent';")" = "1"

if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000003',
  'routing-conflict',
  'ARO-169-disposable',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "routing conflict unexpectedly provisioned a partial node" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_lifecycle_operations where operation_id = '16900000-0000-4000-8000-000000000003';")" = "0"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.nodes where display_alias = 'routing-conflict';")" = "0"

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

psql_admin <<'SQL'
create role aro169_disposable_inherit_only nologin inherit;
grant symphony_staging_provisioner to aro169_disposable_inherit_only
  with inherit true, set false;
SQL
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000104',
    '$node_id',
    '$instance_one'
  );
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed SET capability" >&2
  exit 1
fi
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  update symphony_staging.node_login_principals
  set revoked_at = clock_timestamp()
  where node_id = '$node_id';
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed lifecycle table boundary" >&2
  exit 1
fi
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  update symphony_staging.nodes
  set credential_version = credential_version + 1
  where node_id = '$node_id';
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed foundation table boundary" >&2
  exit 1
fi
psql_admin <<'SQL'
revoke symphony_staging_provisioner from aro169_disposable_inherit_only;
drop role aro169_disposable_inherit_only;
SQL

psql_admin <<SQL
create role aro169_disposable_bootstrap nologin noinherit;
grant symphony_staging_provisioner to aro169_disposable_bootstrap
  with inherit false, set true;
set session authorization aro169_disposable_bootstrap;
set role symphony_staging_provisioner;
select * from symphony_staging.retire_node_instance(
  '16900000-0000-4000-8000-000000000101',
  '$node_id',
  '$instance_one'
);
reset session authorization;
drop role aro169_disposable_bootstrap;
SQL
psql_admin -c \
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000101',
    '$node_id',
    '$instance_one'
  );" >/dev/null

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
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000102',
    '$node_id',
    '$instance_two'
  );" \
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
    "select * from symphony_staging.rotate_node_credential(
      '16900000-0000-4000-8000-000000000201',
      '$node_id'
    );"
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
  credential_version rotated_contract_version rotated_secret <<<"$rotated"
unset rotated

test "$credential_version" = "2"
test "$rotated_contract_version" = "3"
test "$rotated_secret" = "t"
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
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000103',
    '$node_id',
    '$instance_four'
  );" \
  >/dev/null

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$rotated_node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_five');" \
  -c "select pg_sleep(4);" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_six');" \
  >/dev/null 2>&1 &
open_session_pid=$!
sleep 1

psql_admin -c "select * from symphony_staging.revoke_node(
  '16900000-0000-4000-8000-000000000301',
  '$node_id'
);" >/dev/null

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

reenrolled="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.reenroll_node(
      '16900000-0000-4000-8000-000000000401',
      '$node_id'
    );"
)"
IFS='|' read -r _reenrolled_node_id reenrolled_role reenrolled_credential \
  reenrolled_version reenrolled_contract reenrolled_secret <<<"$reenrolled"
unset reenrolled
test "$_reenrolled_node_id" = "$node_id"
test "$reenrolled_version" = "3"
test "$reenrolled_contract" = "3"
test "$reenrolled_secret" = "t"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_principal_history where node_id = '$node_id';")" = "3"

reenroll_replay="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.reenroll_node(
      '16900000-0000-4000-8000-000000000401',
      '$node_id'
    );"
)"
IFS='|' read -r _ _ replayed_reenroll_credential _ _ replayed_reenroll_secret \
  <<<"$reenroll_replay"
unset reenroll_replay
test -z "$replayed_reenroll_credential"
test "$replayed_reenroll_secret" = "f"
unset reenrolled_credential

if psql_admin -f \
  "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly orphaned a provisioned principal" >&2
  exit 1
fi

psql_admin <<SQL
select format(
  'revoke execute on function symphony_staging.authenticate_node(uuid, uuid) from %I',
  login_role
)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
select format('revoke usage on schema symphony_staging from %I', login_role)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
select format('drop role %I', login_role)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
delete from symphony_staging.foundation_audit_events
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
);
delete from symphony_staging.routing_assignments where issue_id = 'ARO-169-concurrent';
delete from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_login_principals
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_lifecycle_operations
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_bindings
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.nodes where display_alias = 'concurrent-node';

revoke execute on function symphony_staging.authenticate_node(uuid, uuid)
  from "$reenrolled_role";
revoke usage on schema symphony_staging from "$reenrolled_role";
delete from symphony_staging.foundation_audit_events where node_id = '$node_id';
delete from symphony_staging.active_node_instances where node_id = '$node_id';
delete from symphony_staging.node_instance_history where node_id = '$node_id';
delete from symphony_staging.routing_assignments where target_node_id = '$node_id';
delete from symphony_staging.node_lifecycle_operations where node_id = '$node_id';
delete from symphony_staging.node_bindings where node_id = '$node_id';
delete from symphony_staging.node_login_principals where node_id = '$node_id';
delete from symphony_staging.node_principal_history where node_id = '$node_id';
delete from symphony_staging.nodes where node_id = '$node_id';
drop role "$login_role";
drop role "$_rotated_role";
drop role "$reenrolled_role";
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

psql_admin -c "
  create index aro169_drifted_active_instance_authenticated_at_idx
  on symphony_staging.active_node_instances (authenticated_at);
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted index drift" >&2
  exit 1
fi
psql_admin -c "
  drop index symphony_staging.aro169_drifted_active_instance_authenticated_at_idx;
" >/dev/null

if psql_admin \
  -c "begin; grant select on symphony_staging.active_node_instances to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted ACL drift" >&2
  exit 1
fi
if psql_admin \
  -c "begin; grant select (node_id) on symphony_staging.node_login_principals to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted column ACL drift" >&2
  exit 1
fi
if psql_admin \
  -c "begin;
      create function symphony_staging.aro169_drift_trigger()
      returns trigger language plpgsql
      set search_path = pg_catalog
      as \$\$ begin return new; end \$\$;
      create trigger aro169_drift_trigger
      before update on symphony_staging.nodes
      for each row execute function symphony_staging.aro169_drift_trigger();" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted trigger drift" >&2
  exit 1
fi
psql_admin -c "
  grant symphony_staging_provisioner to service_role
    with inherit false, set true;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted membership drift" >&2
  exit 1
fi
psql_admin -c "
  revoke symphony_staging_provisioner from service_role;
" >/dev/null

psql_admin -c "
  alter sequence symphony_staging.foundation_audit_events_audit_id_seq
    increment by 2 cache 3 cycle;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted sequence drift" >&2
  exit 1
fi
psql_admin -c "
  alter sequence symphony_staging.foundation_audit_events_audit_id_seq
    increment by 1 cache 1 no cycle;
" >/dev/null

psql_admin -c "
  alter role symphony_staging_provisioner login;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted managed-role attribute drift" >&2
  exit 1
fi
psql_admin -c "
  alter role symphony_staging_provisioner nologin;
" >/dev/null

psql_admin -c "
  grant create on schema symphony_staging to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted schema ACL drift" >&2
  exit 1
fi
psql_admin -c "
  revoke create on schema symphony_staging from service_role;
" >/dev/null

psql_admin -c "
  alter table symphony_staging.nodes force row level security;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted FORCE RLS drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.nodes no force row level security;
" >/dev/null

psql_admin -c "
  create table symphony_staging.aro169_unexpected_v3_object(id integer);
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted extra staging object" >&2
  exit 1
fi
psql_admin -c "
  drop table symphony_staging.aro169_unexpected_v3_object;
" >/dev/null

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
test "$(psql_admin -A -t -c "select has_table_privilege('symphony_staging_provisioner', 'symphony_staging.nodes', 'SELECT,INSERT,UPDATE');")" = "t"
test "$(psql_admin -A -t -c "select count(*) from pg_policies where schemaname = 'symphony_staging' and policyname in ('provisioner_manage_nodes', 'provisioner_manage_node_bindings', 'provisioner_manage_routing_assignments') and roles = array['symphony_staging_provisioner']::name[];")" = "3"
psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

echo "ARO-169 disposable PostgreSQL lifecycle passed without printing credentials"
