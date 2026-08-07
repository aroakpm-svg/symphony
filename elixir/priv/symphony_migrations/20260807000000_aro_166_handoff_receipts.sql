begin;

create table symphony_staging.handoff_receipts (
  checkpoint_sequence bigint generated always as identity primary key,
  receipt_schema_version integer not null check (receipt_schema_version = 1),
  issue_id text not null,
  canonical_owner text not null check (btrim(canonical_owner) <> ''),
  canonical_repository text not null check (btrim(canonical_repository) <> ''),
  claim_id uuid not null,
  generation bigint not null check (generation > 0),
  recorded_at timestamptz not null default clock_timestamp(),
  branch text not null check (btrim(branch) <> ''),
  commit_sha text check (commit_sha is null or commit_sha ~ '^[0-9a-f]{40}$'),
  pr_number integer check (pr_number is null or pr_number > 0),
  current_phase text not null check (current_phase in (
    'preflight', 'implementation', 'verification', 'delivery', 'review', 'complete'
  )),
  completed_step_ids text[] not null default '{}',
  pending_step_ids text[] not null default '{}',
  test_results jsonb not null default '[]'::jsonb,
  effect_operation_ids text[] not null default '{}',
  constraint handoff_receipt_claim_fk
    foreign key (issue_id) references symphony_staging.issue_claims(issue_id)
);

create index handoff_receipts_latest
  on symphony_staging.handoff_receipts (issue_id, generation desc, checkpoint_sequence desc);

alter table symphony_staging.handoff_receipts enable row level security;
revoke all on table symphony_staging.handoff_receipts
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.validate_handoff_steps(
  completed text[], pending text[]
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  with allowed(step_id) as (
    values ('preflight'), ('branch'), ('implementation'), ('tests'),
           ('commit'), ('push'), ('pull_request'), ('review')
  )
  select
    completed is not null
    and pending is not null
    and coalesce(array_ndims(completed), 1) = 1
    and coalesce(array_ndims(pending), 1) = 1
    and coalesce(array_length(completed, 1), 0) =
      (select count(distinct value) from unnest(completed) value)
    and coalesce(array_length(pending, 1), 0) =
      (select count(distinct value) from unnest(pending) value)
    and not exists (
      select 1 from unnest(completed || pending) value
      where value not in (select step_id from allowed)
    )
    and not exists (select 1 from unnest(completed) value where value = any(pending))
$$;

create or replace function symphony_staging.validate_handoff_tests(results jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select jsonb_typeof(results) = 'array'
    and not exists (
      select 1 from jsonb_array_elements(results) result
      where jsonb_typeof(result) <> 'object'
        or (select array_agg(key order by key) from jsonb_object_keys(result) key)
           is distinct from array['name', 'status']::text[]
        or jsonb_typeof(result->'name') is distinct from 'string'
        or btrim(result->>'name') = ''
        or jsonb_typeof(result->'status') is distinct from 'string'
        or result->>'status' is null
        or result->>'status' not in ('passed', 'failed', 'skipped')
    )
$$;

create or replace function symphony_staging.append_handoff_receipt(
  requested_issue_id text,
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_schema_version integer,
  requested_owner text,
  requested_repository text,
  requested_branch text,
  requested_commit_sha text,
  requested_pr_number integer,
  requested_phase text,
  requested_completed text[],
  requested_pending text[],
  requested_test_results jsonb,
  requested_effect_operation_ids text[]
)
returns table (
  receipt_schema_version integer,
  issue_id text,
  canonical_owner text,
  canonical_repository text,
  claim_id uuid,
  generation bigint,
  checkpoint_sequence bigint,
  recorded_at timestamptz,
  branch text,
  commit_sha text,
  pr_number integer,
  current_phase text,
  completed_step_ids text[],
  pending_step_ids text[],
  test_results jsonb,
  effect_operation_ids text[]
)
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  inserted symphony_staging.handoff_receipts%rowtype;
begin
  perform 1
  from symphony_staging.issue_claims claims
  join symphony_staging.nodes nodes on nodes.node_id = claims.node_id
  join symphony_staging.node_login_principals principals
    on principals.node_id = nodes.node_id
   and principals.login_role = session_user
   and principals.revoked_at is null
  join symphony_staging.active_node_instances instances
    on instances.node_id = claims.node_id
   and instances.node_instance_id = claims.node_instance_id
  where claims.issue_id = requested_issue_id
    and claims.claim_id = requested_claim_id
    and claims.generation = requested_generation
    and claims.node_id = requested_node_id
    and claims.node_instance_id = requested_node_instance_id
    and nodes.status = 'active'
    and claims.completed_at is null
    and claims.released_at is null
    and claims.lease_expires_at > clock_timestamp()
  for update of claims;

  if not found then
    raise exception using errcode = '55000',
      message = 'receipt requires a matching active claim generation';
  end if;

  if requested_schema_version <> 1
     or requested_owner is null or btrim(requested_owner) = ''
     or requested_repository is null or btrim(requested_repository) = ''
     or requested_branch is null or btrim(requested_branch) = ''
     or requested_phase not in (
       'preflight', 'implementation', 'verification', 'delivery', 'review', 'complete'
     )
     or not symphony_staging.validate_handoff_steps(requested_completed, requested_pending)
     or not symphony_staging.validate_handoff_tests(requested_test_results)
     or requested_effect_operation_ids is null
     or coalesce(array_ndims(requested_effect_operation_ids), 1) <> 1
     or coalesce(array_length(requested_effect_operation_ids, 1), 0) <>
       (select count(distinct value) from unnest(requested_effect_operation_ids) value)
     or exists (
       select 1 from unnest(requested_effect_operation_ids) value
       where value is null or btrim(value) = ''
     ) then
    raise exception using errcode = '22023', message = 'invalid HandoffReceiptV1';
  end if;

  insert into symphony_staging.handoff_receipts (
    receipt_schema_version, issue_id, canonical_owner, canonical_repository,
    claim_id, generation, branch, commit_sha, pr_number, current_phase,
    completed_step_ids, pending_step_ids, test_results, effect_operation_ids
  ) values (
    requested_schema_version, requested_issue_id, requested_owner, requested_repository,
    requested_claim_id, requested_generation, requested_branch, requested_commit_sha,
    requested_pr_number, requested_phase, requested_completed, requested_pending,
    requested_test_results, requested_effect_operation_ids
  ) returning * into inserted;

  return query select
    inserted.receipt_schema_version,
    inserted.issue_id,
    inserted.canonical_owner,
    inserted.canonical_repository,
    inserted.claim_id,
    inserted.generation,
    inserted.checkpoint_sequence,
    inserted.recorded_at,
    inserted.branch,
    inserted.commit_sha,
    inserted.pr_number,
    inserted.current_phase,
    inserted.completed_step_ids,
    inserted.pending_step_ids,
    inserted.test_results,
    inserted.effect_operation_ids;
end
$$;

create or replace function symphony_staging.latest_handoff_receipt(
  requested_issue_id text,
  active_claim_id uuid,
  active_generation bigint,
  active_node_id uuid,
  active_node_instance_id uuid
)
returns table (
  receipt_schema_version integer,
  issue_id text,
  canonical_owner text,
  canonical_repository text,
  claim_id uuid,
  generation bigint,
  checkpoint_sequence bigint,
  recorded_at timestamptz,
  branch text,
  commit_sha text,
  pr_number integer,
  current_phase text,
  completed_step_ids text[],
  pending_step_ids text[],
  test_results jsonb,
  effect_operation_ids text[]
)
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if not symphony_staging.validate_active_claim(
    active_claim_id, active_generation, active_node_id, active_node_instance_id
  ) then
    raise exception using errcode = '55000', message = 'handoff read requires an active claim';
  end if;

  if not exists (
    select 1 from symphony_staging.issue_claims claims
    where claims.issue_id = requested_issue_id
      and claims.claim_id = active_claim_id
  ) then
    raise exception using errcode = '55000', message = 'active claim issue mismatch';
  end if;

  return query
  select
    receipts.receipt_schema_version,
    receipts.issue_id,
    receipts.canonical_owner,
    receipts.canonical_repository,
    receipts.claim_id,
    receipts.generation,
    receipts.checkpoint_sequence,
    receipts.recorded_at,
    receipts.branch,
    receipts.commit_sha,
    receipts.pr_number,
    receipts.current_phase,
    receipts.completed_step_ids,
    receipts.pending_step_ids,
    receipts.test_results,
    receipts.effect_operation_ids
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
  order by receipts.generation desc, receipts.checkpoint_sequence desc
  limit 1;
end
$$;

create or replace function symphony_staging.handoff_receipt_ready()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select exists (
    select 1 from symphony_staging.contract_versions
    where contract_name = 'handoff-receipt' and contract_version >= 1
  )
$$;

revoke all on function
  symphony_staging.validate_handoff_steps(text[], text[]),
  symphony_staging.validate_handoff_tests(jsonb),
  symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, integer, text, text[], text[], jsonb, text[]),
  symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid),
  symphony_staging.handoff_receipt_ready()
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, integer, text, text[], text[], jsonb, text[]),
  symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid),
  symphony_staging.handoff_receipt_ready()
  to symphony_staging_runtime;

create or replace function symphony_staging.grant_handoff_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, integer, text, text[], text[], jsonb, text[]), '
    'symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid), '
    'symphony_staging.handoff_receipt_ready() to %I',
    new.login_role
  );
  return new;
end
$$;

revoke all on function symphony_staging.grant_handoff_api_to_node_login()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop trigger if exists grant_handoff_api_to_node_login on symphony_staging.node_login_principals;
create trigger grant_handoff_api_to_node_login
after insert or update of login_role on symphony_staging.node_login_principals
for each row execute function symphony_staging.grant_handoff_api_to_node_login();

do $$
declare principal record;
begin
  for principal in select login_role from symphony_staging.node_login_principals loop
    execute format(
      'grant execute on function '
      'symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, integer, text, text[], text[], jsonb, text[]), '
      'symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid), '
      'symphony_staging.handoff_receipt_ready() to %I', principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (contract_name, contract_version, migration_name)
values ('handoff-receipt', 1, '20260807000000_aro_166_handoff_receipts')
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
