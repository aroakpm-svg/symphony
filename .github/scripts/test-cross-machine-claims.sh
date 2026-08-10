#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
database_url="${TEST_DATABASE_URL:?TEST_DATABASE_URL is required}"
migration="$root_dir/elixir/priv/symphony_migrations/20260804000000_aro_164_cross_machine_claims.sql"
effect_migration="$root_dir/elixir/priv/symphony_migrations/20260805000000_aro_165_effect_ledger.sql"
effect_rollback="$root_dir/elixir/priv/symphony_migrations/20260805000000_aro_165_effect_ledger.down.sql"
handoff_migration="$root_dir/elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.sql"
handoff_rollback="$root_dir/elixir/priv/symphony_migrations/20260806000000_aro_166_handoff_receipts.down.sql"
retry_migration="$root_dir/elixir/priv/symphony_migrations/20260810000000_aro_166_handoff_retry_semantics.sql"
retry_rollback="$root_dir/elixir/priv/symphony_migrations/20260810000000_aro_166_handoff_retry_semantics.down.sql"

psql_admin() { psql -X -q -v ON_ERROR_STOP=1 -d "$database_url" "$@"; }
node_url() { printf 'postgresql://%s:disposable@localhost:5432/postgres' "$1"; }
uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    echo "no UUID generator available" >&2
    return 1
  fi
}
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
  ('EFFECTS','unassigned',null,1,1), ('HANDOFF','unassigned',null,1,1),
  ('HANDOFF-WHITESPACE','unassigned',null,1,1);
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
psql_admin -f "$handoff_migration"

psql_admin <<'SQL'
insert into symphony_staging.handoff_receipts (
  checkpoint_sequence, receipt_schema_version, issue_id, repository, claim_id, generation,
  checkpoint_kind, branch, head_sha, tested_head_sha, pr_number,
  test_results, effect_operation_ids
) overriding system value
values
  (9001, 1, 'MIGRATION-BINDING', 'aroakpm-svg/symphony',
   '40000000-0000-0000-0000-000000000001', 1, 'pushed',
   'branch-a', repeat('a', 40), repeat('a', 40), null,
   '[{"name":"migration","status":"passed"}]', '{}'),
  (9002, 1, 'MIGRATION-BINDING', 'aroakpm-svg/symphony',
   '40000000-0000-0000-0000-000000000001', 1, 'pull_request',
   'branch-a', repeat('b', 40), repeat('b', 40), 24,
   '[{"name":"migration","status":"passed"}]', '{}');
SQL

binding_preflight_output="$tmp_dir/binding-preflight"
if psql_admin -f "$retry_migration" >"$binding_preflight_output" 2>&1; then
  echo "retry migration unexpectedly accepted incompatible legacy generation bindings" >&2
  exit 1
fi
grep -q "legacy generation bindings" "$binding_preflight_output"
psql_admin -c "delete from symphony_staging.handoff_receipts where issue_id = 'MIGRATION-BINDING';"

psql_admin <<'SQL'
insert into symphony_staging.handoff_receipts (
  checkpoint_sequence, receipt_schema_version, issue_id, repository, claim_id, generation,
  checkpoint_kind, branch, head_sha, tested_head_sha, pr_number,
  test_results, effect_operation_ids
) overriding system value
values
  (9011, 1, 'MIGRATION-RANK', 'aroakpm-svg/symphony',
   '40000000-0000-0000-0000-000000000002', 1, 'reviewed',
   'branch-a', repeat('a', 40), repeat('a', 40), 24,
   '[{"name":"migration","status":"passed"}]', '{}'),
  (9012, 1, 'MIGRATION-RANK', 'aroakpm-svg/symphony',
   '40000000-0000-0000-0000-000000000002', 1, 'pushed',
   'branch-a', repeat('a', 40), repeat('a', 40), null,
   '[{"name":"migration","status":"passed"}]', '{}');
SQL

rank_preflight_output="$tmp_dir/rank-preflight"
if psql_admin -f "$retry_migration" >"$rank_preflight_output" 2>&1; then
  echo "retry migration unexpectedly accepted a legacy checkpoint rank regression" >&2
  exit 1
fi
grep -q "legacy checkpoint rank regressions" "$rank_preflight_output"
psql_admin -c "delete from symphony_staging.handoff_receipts where issue_id = 'MIGRATION-RANK';"
psql_admin -f "$retry_migration"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations_issue_operation_idx') is not null;")" = "t"

psql_admin -c "insert into symphony_staging.handoff_receipts (
    checkpoint_sequence, receipt_schema_version, issue_id, repository, claim_id, generation,
    checkpoint_kind, branch, head_sha, tested_head_sha, pr_number,
    test_results, effect_operation_ids
  ) overriding system value values (
    9021, 1, 'MIGRATION-STALE-BODY', 'aroakpm-svg/symphony',
    '40000000-0000-0000-0000-000000000003', 1,
    'reviewed', 'branch-a', repeat('a', 40), repeat('a', 40), 24,
    '[{\"name\":\"migration\",\"status\":\"passed\"}]'::jsonb, '{}'
  );"
stale_body_output="$tmp_dir/stale-v1-body"
if psql_admin -c "insert into symphony_staging.handoff_receipts (
    checkpoint_sequence, receipt_schema_version, issue_id, repository, claim_id, generation,
    checkpoint_kind, branch, head_sha, tested_head_sha, pr_number,
    test_results, effect_operation_ids
  ) overriding system value values (
    9022, 1, 'MIGRATION-STALE-BODY', 'aroakpm-svg/symphony',
    '40000000-0000-0000-0000-000000000003', 1,
    'pushed', 'branch-a', repeat('a', 40), repeat('a', 40), null,
    '[{\"name\":\"migration\",\"status\":\"passed\"}]'::jsonb, '{}'
  );" >"$stale_body_output" 2>&1; then
  echo "V2 insert enforcement unexpectedly accepted a distinct stale V1 checkpoint regression" >&2
  exit 1
fi
grep -q "handoff receipt checkpoint rank cannot regress" "$stale_body_output"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.handoff_receipts where issue_id = 'MIGRATION-STALE-BODY';")" = "1"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.effect_ledger_ready();")" = "t"

effect_claim="$(claim claim_node_c EFFECTS "$node_c" "$instance_c")"
effect_claim_id="${effect_claim%:*}"
effect_generation="${effect_claim#*:}"

for effect_type in linear_comment github_comment git_commit git_push github_pr_create github_pr_update linear_state; do
  operation_id="effect-$effect_type"
  attempt_id="$(uuid)"
  begun="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select status from symphony_staging.begin_effect('$operation_id','$effect_type','fp-$effect_type','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$attempt_id',300000);")"
  test "$begun" = "pending"
  finished="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select symphony_staging.finish_effect('$operation_id','fp-$effect_type','$attempt_id','succeeded','{\"native_id\":\"$operation_id\"}'::jsonb,null);")"
  test "$finished" = "t"
  repeated="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
    "select status from symphony_staging.begin_effect('$operation_id','$effect_type','fp-$effect_type','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$(uuid)',300000);")"
  test "$repeated" = "succeeded"
done

first_attempt_id="$(uuid)"
second_attempt_id="$(uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-concurrent','linear_comment','fp-concurrent','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$first_attempt_id',300000);")" = "pending"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-concurrent','linear_comment','fp-concurrent','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$second_attempt_id',300000);")" = "in-flight"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('effect-concurrent','fp-concurrent','$first_attempt_id','succeeded','{\"native_id\":\"effect-concurrent\"}'::jsonb,null);")" = "t"

relinquish_first_attempt_id="$(uuid)"
relinquish_second_attempt_id="$(uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-relinquish','linear_state','fp-relinquish','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$relinquish_first_attempt_id',300000);")" = "pending"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.relinquish_effect('effect-relinquish','fp-relinquish','$relinquish_first_attempt_id');")" = "t"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-relinquish','linear_state','fp-relinquish','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$relinquish_second_attempt_id',300000);")" = "pending"

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-linear_comment','linear_comment','different-fingerprint','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$(uuid)',300000);" \
  >/dev/null 2>&1; then
  echo "effect ledger unexpectedly accepted request fingerprint drift" >&2; exit 1
fi

unknown_attempt_id="$(uuid)"
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-unknown','github_pr_create','fp-unknown','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$unknown_attempt_id',300000);" \
  >/dev/null
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('effect-unknown','fp-unknown','$unknown_attempt_id','unknown',null,'timeout');" \
  >/dev/null
reconcile_attempt_id="$(uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-unknown','github_pr_create','fp-unknown','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$reconcile_attempt_id',300000);")" = "unknown"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select symphony_staging.reconcile_effect('effect-unknown','fp-unknown','$reconcile_attempt_id','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','succeeded','{\"number\":18}'::jsonb);")" = "f"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.reconcile_effect('effect-unknown','fp-unknown','$reconcile_attempt_id','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','succeeded','{\"number\":18}'::jsonb);")" = "t"

handoff_attempt_id="$(uuid)"
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-handoff','linear_comment','fp-handoff','EFFECTS','$effect_claim_id',$effect_generation,'$node_c','$instance_c','$handoff_attempt_id',300000);" \
  >/dev/null
PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('effect-handoff','fp-handoff','$handoff_attempt_id','unknown',null,'timeout');" \
  >/dev/null
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'EFFECTS';"
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'TAKEOVER';"
handoff_claim="$(claim claim_node_b EFFECTS "$node_b" "$instance_b")"
handoff_claim_id="${handoff_claim%:*}"
handoff_generation="${handoff_claim#*:}"
handoff_reconcile_attempt_id="$(uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select status from symphony_staging.begin_effect('effect-handoff','linear_comment','fp-handoff','EFFECTS','$handoff_claim_id',$handoff_generation,'$node_b','$instance_b','$handoff_reconcile_attempt_id',300000);")" = "unknown"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select symphony_staging.reconcile_effect('effect-handoff','fp-handoff','$handoff_reconcile_attempt_id','EFFECTS','$handoff_claim_id',$handoff_generation,'$node_b','$instance_b','failed-no-effect',null);")" = "t"

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('effect-stale','git_push','fp-stale','TAKEOVER','$old_id',$old_generation,'$node_c','$instance_c','$(uuid)',300000);" \
  >/dev/null 2>&1; then
  echo "effect ledger unexpectedly accepted a stale generation" >&2; exit 1
fi

psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'EFFECTS';"
handoff_receipt_claim="$(claim claim_node_c HANDOFF "$node_c" "$instance_c")"
handoff_receipt_claim_id="${handoff_receipt_claim%:*}"
handoff_receipt_generation="${handoff_receipt_claim#*:}"
handoff_receipt_attempt_id="$(uuid)"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select status from symphony_staging.begin_effect('handoff-git-push','git_push','fp-handoff-git-push','HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','$handoff_receipt_attempt_id',300000);")" = "pending"
test "$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select symphony_staging.finish_effect('handoff-git-push','fp-handoff-git-push','$handoff_receipt_attempt_id','succeeded','{\"native_id\":\"handoff-git-push\"}'::jsonb,null);")" = "t"

pushed="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$pushed" = "1|pushed||{handoff-git-push}"
duplicate_pushed="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$duplicate_pushed" = "1|pushed||{handoff-git-push}"
pull_request="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pull_request','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',23,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$pull_request" = "2|pull_request|23|{handoff-git-push}"
reviewed="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','reviewed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',23,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$reviewed" = "3|reviewed|23|{handoff-git-push}"

psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'PREFERRED';"
whitespace_claim="$(claim claim_node_a HANDOFF-WHITESPACE "$node_a" "$instance_a")"
whitespace_claim_id="${whitespace_claim%:*}"
whitespace_generation="${whitespace_claim#*:}"
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_a)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF-WHITESPACE','$whitespace_claim_id',$whitespace_generation,'$node_a','$instance_a','aroakpm-svg/symphony','pushed',repeat(chr(9),1),repeat('c',40),repeat('c',40),null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "tab-only branch unexpectedly persisted a handoff receipt" >&2
  exit 1
fi
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_a)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF-WHITESPACE','$whitespace_claim_id',$whitespace_generation,'$node_a','$instance_a','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('c',40),repeat('c',40),null,jsonb_build_array(jsonb_build_object('name',chr(9),'status','passed')));" \
  >/dev/null 2>&1; then
  echo "tab-only test result name unexpectedly persisted a handoff receipt" >&2
  exit 1
fi
late_pushed="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$late_pushed" = "3|reviewed|23|{handoff-git-push}"

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"skipped\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "lower-ranked checkpoint with conflicting test results unexpectedly accepted" >&2; exit 1
fi

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','reviewed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',23,'[{\"name\":\"make all\",\"status\":\"skipped\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "same-checkpoint conflicting test results unexpectedly accepted" >&2; exit 1
fi
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','reviewed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',24,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "same-generation pull-request identity change unexpectedly accepted" >&2; exit 1
fi

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "same-generation new head unexpectedly accepted" >&2; exit 1
fi

if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "insert into symphony_staging.handoff_receipts (receipt_schema_version, issue_id, repository, claim_id, generation, checkpoint_kind, branch, head_sha, tested_head_sha, pr_number, test_results) values (1,'HANDOFF','aroakpm-svg/symphony','$handoff_receipt_claim_id',$handoff_receipt_generation,'pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "handoff receipt direct insert unexpectedly succeeded" >&2; exit 1
fi
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "update symphony_staging.handoff_receipts set branch = 'codex/aro-166-replacement' where checkpoint_sequence = 1;" \
  >/dev/null 2>&1; then
  echo "handoff receipt direct update unexpectedly succeeded" >&2; exit 1
fi
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "delete from symphony_staging.handoff_receipts where checkpoint_sequence = 1;" \
  >/dev/null 2>&1; then
  echo "handoff receipt direct delete unexpectedly succeeded" >&2; exit 1
fi

psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'HANDOFF';"
handoff_receipt_claim_2="$(claim claim_node_b HANDOFF "$node_b" "$instance_b")"
handoff_receipt_claim_id_2="${handoff_receipt_claim_2%:*}"
handoff_receipt_generation_2="${handoff_receipt_claim_2#*:}"
if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_c)" -c \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id',$handoff_receipt_generation,'$node_c','$instance_c','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);" \
  >/dev/null 2>&1; then
  echo "stale handoff receipt generation unexpectedly accepted" >&2; exit 1
fi
latest_generation_1="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select receipt.generation || '|' || receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.latest_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b') receipt;")"
test "$latest_generation_1" = "1|3|reviewed|23|{handoff-git-push}"
latest_generation_2_receipt="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb) receipt;")"
test "$latest_generation_2_receipt" = "4|pushed||{handoff-git-push}"
latest_generation_2="$(PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$(node_url claim_node_b)" -c \
  "select receipt.generation || '|' || receipt.checkpoint_sequence || '|' || receipt.checkpoint_kind || '|' || coalesce(receipt.pr_number::text, '') || '|' || receipt.effect_operation_ids::text from symphony_staging.latest_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b') receipt;")"
test "$latest_generation_2" = "2|4|pushed||{handoff-git-push}"

expect_handoff_append_failure() {
  local label="$1" statement="$2"
  if PGPASSWORD=disposable psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -d "$(node_url claim_node_b)" -c "$statement" >/dev/null 2>&1; then
    echo "$label unexpectedly accepted" >&2
    exit 1
  fi
}

expect_handoff_append_failure "empty handoff tests" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[]'::jsonb);"
expect_handoff_append_failure "failed handoff test" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[{\"name\":\"make all\",\"status\":\"failed\"}]'::jsonb);"
expect_handoff_append_failure "mismatched tested head" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('c',40),null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
expect_handoff_append_failure "pushed receipt with PR" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','pushed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),23,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
expect_handoff_append_failure "reviewed receipt without PR" \
  "select * from symphony_staging.append_handoff_receipt('HANDOFF','$handoff_receipt_claim_id_2',$handoff_receipt_generation_2,'$node_b','$instance_b','aroakpm-svg/symphony','reviewed','codex/aro-166-replacement',repeat('b',40),repeat('b',40),null,'[{\"name\":\"make all\",\"status\":\"passed\"}]'::jsonb);"
psql_admin -c "update symphony_staging.issue_claims set released_at = clock_timestamp() where issue_id = 'HANDOFF';"

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
psql_admin -f "$retry_rollback"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations_issue_operation_idx') is null;")" = "t"
psql_admin -f "$handoff_rollback"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.handoff_receipts') is null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations') is not null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.issue_claims') is not null;")" = "t"
psql_admin -f "$effect_rollback"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.effect_operations') is null;")" = "t"
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.issue_claims') is not null;")" = "t"
psql_admin -c "delete from symphony_staging.active_node_instances where node_id = '$node_a';"

echo "ARO-164/165/166 disposable PostgreSQL claim, effect, and handoff lifecycle passed without printing credentials"
