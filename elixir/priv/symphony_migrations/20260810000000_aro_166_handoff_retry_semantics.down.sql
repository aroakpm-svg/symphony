begin;

delete from symphony_staging.contract_versions
where contract_name = 'handoff-receipts'
  and migration_name = '20260810000000_aro_166_handoff_retry_semantics';

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

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'handoff-receipts', 1, '20260806000000_aro_166_handoff_receipts'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

drop index if exists symphony_staging.handoff_receipts_checkpoint_identity_idx;
drop index if exists symphony_staging.effect_operations_issue_operation_idx;

commit;
