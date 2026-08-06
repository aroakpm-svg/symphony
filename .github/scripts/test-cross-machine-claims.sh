#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
database_url="${TEST_DATABASE_URL:?TEST_DATABASE_URL is required}"
migration="$root_dir/elixir/priv/symphony_migrations/20260804000000_aro_164_cross_machine_claims.sql"
effect_migration="$root_dir/elixir/priv/symphony_migrations/20260805000000_aro_165_effect_ledger.sql"
effect_rollback="$root_dir/elixir/priv/symphony_migrations/20260805000000_aro_165_effect_ledger.down.sql"

psql_admin() { psql -X -q -v ON_ERROR_STOP=1 -d "$database_url" "$@"; }
node_url() { printf 'postgresql://%s:disposable@localhost:5432/postgres' "$1"; }
claim() {
  local role="$1" issue="$2" node="$3" instance="$4" state="${5:-todo}" lease="${6:-60000}" grace="${7:-0}"
  PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url "$role")" \
    -c "select claim_id || ':' || generation from symphony_staging.claim_issue('$issue','$node','$instance',clock_timestamp(),'$state',array['todo','in progress','in review'],$lease,$grace);"
}

psql_admin <<'SQL'
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create role symphony_staging_runtime nologin;
create role symphony_staging_provisioner nologin;
create schema symphony_staging;
grant usage on schema symphony_staging to symphony_staging_runtime, symphony_staging_provisioner;
create table symphony_staging.contract_versions (
  contract_name text primary key, contract_version integer not null,
  migration_name text not null, installed_at timestamptz not null default clock_timestamp()
);
create table symphony_staging.nodes (
  node_id uuid primary key, display_alias text, status text not null,
  credential_version integer not null default 1, created_at timestamptz default clock_timestamp(),
  updated_at timestamptz default clock_timestamp(), rotated_at timestamptz,
  revoked_at timestamptz, retired_at timestamptz
);
create table symphony_staging.routing_assignments (
  issue_id text primary key, routing_policy text not null, target_node_id uuid references symphony_staging.nodes,
  routing_revision bigint not null, contract_version integer not null,
  updated_at timestamptz not null default clock_timestamp()
);
create table symphony_staging.node_login_principals (
  node_id uuid primary key references symphony_staging.nodes,
  login_role name not null unique, created_at timestamptz default clock_timestamp(), revoked_at timestamptz
);
create table symphony_staging.active_node_instances (
  node_id uuid primary key references symphony_staging.node_login_principals,
  node_instance_id uuid not null, authenticated_at timestamptz default clock_timestamp(),
  unique (node_id, node_instance_id)
);
SQL

psql_admin -f "$migration"

node_a=00000000-0000-0000-0000-00000000000a
node_b=00000000-0000-0000-0000-00000000000b
node_c=00000000-0000-0000-0000-00000000000c
instance_a=10000000-0000-0000-0000-00000000000a
instance_b=10000000-0000-0000-0000-00000000000b
instance_c=10000000-0000-0000-0000-00000000000c

psql_admin <<SQL
create role claim_node_a login password 'disposable';
create role claim_node_b login password 'disposable';
create role claim_node_c login password 'disposable';
grant usage on schema symphony_staging to claim_node_a, claim_node_b, claim_node_c;
insert into symphony_staging.nodes(node_id, display_alias, status, claim_capacity) values
  ('$node_a','a','active',2), ('$node_b','b','active',1), ('$node_c','c','active',1);
insert into symphony_staging.node_login_principals(node_id, login_role) values
  ('$node_a','claim_node_a'), ('$node_b','claim_node_b'), ('$node_c','claim_node_c');
insert into symphony_staging.active_node_instances(node_id, node_instance_id) values
  ('$node_a','$instance_a'), ('$node_b','$instance_b'), ('$node_c','$instance_c');
insert into symphony_staging.routing_assignments(issue_id,routing_policy,target_node_id,routing_revision,contract_version) values
  ('RACE','unassigned',null,1,1), ('CAP-A','unassigned',null,1,1), ('CAP-B','unassigned',null,1,1),
  ('CAP-C','unassigned',null,1,1), ('EXCLUSIVE','exclusive','$node_a',1,1),
  ('PREFERRED','preferred-with-fallback','$node_a',1,1), ('TAKEOVER','unassigned',null,1,1),
  ('ROUTE-CHANGE','unassigned',null,1,1), ('CUSTOM-STATE','unassigned',null,1,1),
  ('EFFECTS','unassigned',null,1,1);
SQL

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
claim claim_node_a RACE "$node_a" "$instance_a" >"$tmp_dir/a" & pid_a=$!
claim claim_node_b RACE "$node_b" "$instance_b" >"$tmp_dir/b" & pid_b=$!
claim claim_node_c RACE "$node_c" "$instance_c" >"$tmp_dir/c" & pid_c=$!
successes=0
for pid in "$pid_a" "$pid_b" "$pid_c"; do if wait "$pid"; then successes=$((successes + 1)); fi; done
echo "race successful contenders: $successes"
test "$successes" = 1
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'RACE';"

claim claim_node_a CAP-A "$node_a" "$instance_a" >/dev/null
claim claim_node_a CAP-B "$node_a" "$instance_a" >/dev/null
if claim claim_node_a CAP-C "$node_a" "$instance_a" >/dev/null 2>&1; then
  echo "capacity unexpectedly allowed a final-slot overflow" >&2; exit 1
fi
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id in ('CAP-A','CAP-B');"
if claim claim_node_b EXCLUSIVE "$node_b" "$instance_b" >/dev/null 2>&1; then
  echo "exclusive routing unexpectedly allowed the wrong node" >&2; exit 1
fi
if claim claim_node_b PREFERRED "$node_b" "$instance_b" todo 60000 30000 >/dev/null 2>&1; then
  echo "preferred routing unexpectedly skipped fallback grace" >&2; exit 1
fi
claim claim_node_a PREFERRED "$node_a" "$instance_a" todo 60000 30000 >/dev/null

old="$(claim claim_node_c TAKEOVER "$node_c" "$instance_c" todo 100 0)"
old_id="${old%:*}"; old_generation="${old#*:}"
sleep 0.2
new="$(claim claim_node_b TAKEOVER "$node_b" "$instance_b" 'in progress' 60000 0)"
new_generation="${new#*:}"
test "$new_generation" = 2

psql_admin -f "$effect_migration"

effect_claim="$(claim claim_node_c EFFECTS "$node_c" "$instance_c")"
effect_claim_id="${effect_claim%:*}"
effect_generation="${effect_claim#*:}"

for effect_type in linear_comment github_comment git_commit git_push github_pr_create github_pr_update linear_state; do
  operation_id="effect-$effect_type"
  attempt_id="$(cat /proc/sys/kernel/random/uuid)"
  begun="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select status from symphony_staging.begin_effect('$operation_id','$effect_type','fp-$effect_type','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$attempt_id',300000);")"
  test "$begun" = "pending"
  finished="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select symphony_staging.finish_effect('$operation_id','fp-$effect_type','$attempt_id','succeeded','{\"native_id\":\"$operation_id\"}'::jsonb,null);")"
  test "$finished" = "t"
  repeated="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select status from symphony_staging.begin_effect('$operation_id','$effect_type','fp-$effect_type','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$(cat /proc/sys/kernel/random/uuid)',300000);")"
  test "$repeated" = "succeeded"
done

first_attempt_id="$(cat /proc/sys/kernel/random/uuid)"
second_attempt_id="$(cat /proc/sys/kernel/random/uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-concurrent','linear_comment','fp-concurrent','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$first_attempt_id',300000);")" = "pending"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-concurrent','linear_comment','fp-concurrent','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$second_attempt_id',300000);")" = "in-flight"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('effect-concurrent','fp-concurrent','$first_attempt_id','succeeded','{\"native_id\":\"effect-concurrent\"}'::jsonb,null);")" = "t"

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-linear_comment','linear_comment','different-fingerprint','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$(cat /proc/sys/kernel/random/uuid)',300000);" \
  >/dev/null 2>&1; then
  echo "effect ledger unexpectedly accepted request fingerprint drift" >&2; exit 1
fi

unknown_attempt_id="$(cat /proc/sys/kernel/random/uuid)"
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-unknown','github_pr_create','fp-unknown','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$unknown_attempt_id',300000);" \
  >/dev/null
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('effect-unknown','fp-unknown','$unknown_attempt_id','unknown',null,'timeout');" \
  >/dev/null
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-unknown','github_pr_create','fp-unknown','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$(cat /proc/sys/kernel/random/uuid)',300000);")" = "unknown"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.reconcile_effect('effect-unknown','fp-unknown','succeeded','{\"number\":18}'::jsonb);")" = "t"

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-stale','git_push','fp-stale','TAKEOVER','$old_id',$old_generation,'$node_c','$instance_c','$(cat /proc/sys/kernel/random/uuid)',300000);" \
  >/dev/null 2>&1; then
  echo "effect ledger unexpectedly accepted a stale generation" >&2; exit 1
fi

stale="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.renew_claim('$old_id',$old_generation,'$node_c','$instance_c',60000), symphony_staging.validate_active_claim('$old_id',$old_generation,'$node_c','$instance_c'), symphony_staging.complete_claim('$old_id',$old_generation,'$node_c','$instance_c');")"
test "$stale" = "f|f|f"

routed="$(claim claim_node_a ROUTE-CHANGE "$node_a" "$instance_a")"
routed_id="${routed%:*}"; routed_generation="${routed#*:}"
psql_admin -c "update symphony_staging.routing_assignments set routing_policy = 'exclusive', target_node_id = '$node_b', routing_revision = 2 where issue_id = 'ROUTE-CHANGE';"
if claim claim_node_a ROUTE-CHANGE "$node_a" "$instance_a" >/dev/null 2>&1; then
  echo "same-instance reclaim unexpectedly ignored changed routing" >&2; exit 1
fi
routed_renewal="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_a)" -c \
  "select symphony_staging.renew_claim('$routed_id',$routed_generation,'$node_a','$instance_a',60000);")"
test "$routed_renewal" = "f"
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'ROUTE-CHANGE';"

claim claim_node_a CUSTOM-STATE "$node_a" "$instance_a" 'in review' >/dev/null
psql_admin -f "$effect_rollback"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations') is null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.issue_claims') is not null;")" = "t"
psql_admin -c "delete from symphony_staging.active_node_instances where node_id = '$node_a';"

echo "ARO-164/165 disposable PostgreSQL claim and effect lifecycle passed without printing credentials"
