begin;

create table symphony_staging.handoff_receipts (
  checkpoint_sequence bigint generated always as identity primary key,
  receipt_schema_version integer not null check (receipt_schema_version = 1),
  issue_id text not null check (btrim(issue_id) <> ''),
  repository text not null
    check (repository = lower(repository) and repository ~ '^[a-z0-9_.-]+/[a-z0-9_.-]+$'),
  claim_id uuid not null,
  generation bigint not null check (generation > 0),
  recorded_at timestamptz not null default clock_timestamp(),
  checkpoint_kind text not null check (checkpoint_kind in ('pushed', 'pull_request', 'reviewed')),
  branch text not null check (btrim(branch) <> ''),
  head_sha text not null check (head_sha ~ '^[0-9a-f]{40}$'),
  tested_head_sha text not null check (tested_head_sha ~ '^[0-9a-f]{40}$'),
  pr_number bigint,
  test_results jsonb not null,
  effect_operation_ids text[] not null default '{}',
  constraint handoff_receipt_tested_head_matches check (tested_head_sha = head_sha),
  constraint handoff_receipt_pr_matches_kind check (
    (checkpoint_kind = 'pushed' and pr_number is null) or
    (checkpoint_kind in ('pull_request', 'reviewed') and pr_number > 0)
  ),
  constraint handoff_receipt_test_results_array check (
    case
      when jsonb_typeof(test_results) = 'array'
        then jsonb_array_length(test_results) > 0
      else false
    end
  )
);

alter table symphony_staging.handoff_receipts enable row level security;

revoke all on table symphony_staging.handoff_receipts
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

revoke all on sequence symphony_staging.handoff_receipts_checkpoint_sequence_seq
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.append_handoff_receipt(
  requested_issue_id text,
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_repository text,
  requested_checkpoint_kind text,
  requested_branch text,
  requested_head_sha text,
  requested_tested_head_sha text,
  requested_pr_number bigint,
  requested_test_results jsonb
)
returns symphony_staging.handoff_receipts
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  derived_effect_operation_ids text[];
  inserted_receipt symphony_staging.handoff_receipts%rowtype;
begin
  if requested_issue_id is null
     or btrim(requested_issue_id) = ''
     or requested_repository is null
     or btrim(requested_repository) = ''
     or requested_branch is null
     or btrim(requested_branch) = ''
     or requested_checkpoint_kind is null
     or requested_head_sha is null
     or requested_tested_head_sha is null
     or requested_test_results is null then
    raise exception using errcode = '22023', message = 'handoff receipt identity and content are required';
  end if;

  if requested_repository <> lower(requested_repository)
     or requested_repository !~ '^[a-z0-9_.-]+/[a-z0-9_.-]+$' then
    raise exception using errcode = '22023', message = 'repository must be a lowercase owner/name identifier';
  end if;

  if requested_checkpoint_kind not in ('pushed', 'pull_request', 'reviewed') then
    raise exception using errcode = '22023', message = 'invalid handoff receipt checkpoint kind';
  end if;

  if requested_head_sha !~ '^[0-9a-f]{40}$'
     or requested_tested_head_sha !~ '^[0-9a-f]{40}$' then
    raise exception using errcode = '22023', message = 'handoff receipt head SHA must be a lowercase 40-character hexadecimal value';
  end if;

  if requested_tested_head_sha <> requested_head_sha then
    raise exception using errcode = '22023', message = 'tested head SHA must match head SHA';
  end if;

  if (requested_checkpoint_kind = 'pushed' and requested_pr_number is not null)
     or (requested_checkpoint_kind in ('pull_request', 'reviewed')
         and (requested_pr_number is null or requested_pr_number <= 0)) then
    raise exception using errcode = '22023', message = 'pull request number does not match checkpoint kind';
  end if;

  if jsonb_typeof(requested_test_results) <> 'array' then
    raise exception using errcode = '22023', message = 'test results must be a non-empty JSON array';
  end if;

  if jsonb_array_length(requested_test_results) = 0 then
    raise exception using errcode = '22023', message = 'test results must be a non-empty JSON array';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(requested_test_results) item
    where jsonb_typeof(item) <> 'object'
       or not (item ? 'name' and item ? 'status')
       or item - 'name' - 'status' <> '{}'::jsonb
       or jsonb_typeof(item -> 'name') <> 'string'
       or jsonb_typeof(item -> 'status') <> 'string'
       or item ->> 'name' is null
       or item ->> 'status' is null
       or nullif(btrim(item ->> 'name'), '') is null
       or item ->> 'status' not in ('passed', 'skipped')
  ) then
    raise exception using errcode = '22023', message = 'test results must contain only passed or skipped named tests';
  end if;

  perform 1
  from symphony_staging.issue_claims claims
  join symphony_staging.nodes nodes
    on nodes.node_id = claims.node_id
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
    raise exception using errcode = '55000', message = 'handoff receipt requires a matching active claim generation';
  end if;

  select coalesce(
    array_agg(operations.operation_id order by operations.operation_id),
    '{}'::text[]
  )
  into derived_effect_operation_ids
  from symphony_staging.effect_operations operations
  where operations.issue_id = requested_issue_id;

  insert into symphony_staging.handoff_receipts (
    receipt_schema_version,
    issue_id,
    repository,
    claim_id,
    generation,
    checkpoint_kind,
    branch,
    head_sha,
    tested_head_sha,
    pr_number,
    test_results,
    effect_operation_ids
  ) values (
    1,
    requested_issue_id,
    requested_repository,
    requested_claim_id,
    requested_generation,
    requested_checkpoint_kind,
    requested_branch,
    requested_head_sha,
    requested_tested_head_sha,
    requested_pr_number,
    requested_test_results,
    derived_effect_operation_ids
  )
  returning * into inserted_receipt;

  return inserted_receipt;
end
$$;

create or replace function symphony_staging.latest_handoff_receipt(
  requested_issue_id text,
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns setof symphony_staging.handoff_receipts
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  perform 1
  from symphony_staging.issue_claims claims
  join symphony_staging.nodes nodes
    on nodes.node_id = claims.node_id
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
    raise exception using errcode = '55000', message = 'handoff receipt requires a matching active claim generation';
  end if;

  return query
  select receipts.*
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
  order by receipts.generation desc, receipts.checkpoint_sequence desc
  limit 1;
end
$$;

revoke all on function
  symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb),
  symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid)
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb),
  symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid)
  to symphony_staging_runtime;

create or replace function symphony_staging.grant_handoff_receipt_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb), '
    'symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid) to %I',
    new.login_role
  );
  return new;
end
$$;

revoke all on function symphony_staging.grant_handoff_receipt_api_to_node_login()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop trigger if exists grant_handoff_receipt_api_to_node_login
  on symphony_staging.node_login_principals;
create trigger grant_handoff_receipt_api_to_node_login
after insert or update of login_role on symphony_staging.node_login_principals
for each row execute function symphony_staging.grant_handoff_receipt_api_to_node_login();

do $$
declare
  principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals
  loop
    execute format(
      'grant execute on function '
      'symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb), '
      'symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid) to %I',
      principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'handoff-receipts', 1, '20260806000000_aro_166_handoff_receipts'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

commit;
