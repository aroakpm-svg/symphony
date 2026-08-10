begin;

-- Every V1 append takes a ROW SHARE lock on issue_claims before it can reach
-- the receipt insert. Taking this lock first drains in-flight V1 calls and
-- blocks new ones at their claim check for the entire install transaction.
-- The receipt-table lock then keeps the validated history stable.
lock table symphony_staging.issue_claims in exclusive mode;
lock table symphony_staging.handoff_receipts in share row exclusive mode;

do $$
begin
  if exists (
    select 1
    from symphony_staging.handoff_receipts receipts
    group by
      receipts.issue_id,
      receipts.claim_id,
      receipts.generation,
      receipts.checkpoint_kind,
      receipts.head_sha,
      coalesce(receipts.pr_number, 0)
    having count(*) > 1
  ) then
    raise exception using
      errcode = '55000',
      message = 'handoff retry migration requires unique checkpoint identities; legacy duplicate checkpoint identities must be reconciled before contract version 2 can be installed';
  end if;

  if exists (
    select 1
    from symphony_staging.handoff_receipts receipts
    group by receipts.issue_id, receipts.claim_id, receipts.generation
    having count(distinct receipts.repository) > 1
       or count(distinct receipts.branch) > 1
       or count(distinct receipts.head_sha) > 1
       or count(distinct receipts.pr_number) filter (where receipts.pr_number is not null) > 1
  ) then
    raise exception using
      errcode = '55000',
      message = 'handoff retry migration requires valid generation bindings; legacy generation bindings must be reconciled before contract version 2 can be installed';
  end if;

  if exists (
    select 1
    from (
      select
        receipts.checkpoint_sequence,
        case receipts.checkpoint_kind
          when 'pushed' then 1
          when 'pull_request' then 2
          when 'reviewed' then 3
        end as checkpoint_rank,
        max(
          case receipts.checkpoint_kind
            when 'pushed' then 1
            when 'pull_request' then 2
            when 'reviewed' then 3
          end
        ) over (
          partition by receipts.issue_id, receipts.claim_id, receipts.generation
          order by receipts.checkpoint_sequence
          rows between unbounded preceding and 1 preceding
        ) as prior_checkpoint_rank
      from symphony_staging.handoff_receipts receipts
    ) ranked_receipts
    where ranked_receipts.prior_checkpoint_rank > ranked_receipts.checkpoint_rank
  ) then
    raise exception using
      errcode = '55000',
      message = 'handoff retry migration requires monotonic checkpoint history; legacy checkpoint rank regressions must be reconciled before contract version 2 can be installed';
  end if;
end
$$;

create or replace function symphony_staging.enforce_handoff_receipt_v2_insert()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  existing_pr_number bigint;
  highest_checkpoint_rank integer;
  requested_checkpoint_rank integer;
begin
  if exists (
    select 1
    from symphony_staging.handoff_receipts receipts
    where receipts.issue_id = new.issue_id
      and receipts.claim_id = new.claim_id
      and receipts.generation = new.generation
      and (
        receipts.repository <> new.repository
        or receipts.branch <> new.branch
        or receipts.head_sha <> new.head_sha
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'handoff receipt generation is bound to another repository, branch, or head';
  end if;

  select min(receipts.pr_number)
  into existing_pr_number
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = new.issue_id
    and receipts.claim_id = new.claim_id
    and receipts.generation = new.generation
    and receipts.pr_number is not null;

  if existing_pr_number is not null
     and new.pr_number is not null
     and existing_pr_number <> new.pr_number then
    raise exception using
      errcode = '22023',
      message = 'handoff receipt generation is bound to another pull request';
  end if;

  requested_checkpoint_rank := case new.checkpoint_kind
    when 'pushed' then 1
    when 'pull_request' then 2
    when 'reviewed' then 3
  end;

  select max(
    case receipts.checkpoint_kind
      when 'pushed' then 1
      when 'pull_request' then 2
      when 'reviewed' then 3
    end
  )
  into highest_checkpoint_rank
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = new.issue_id
    and receipts.claim_id = new.claim_id
    and receipts.generation = new.generation;

  if highest_checkpoint_rank > requested_checkpoint_rank then
    raise exception using
      errcode = '22023',
      message = 'handoff receipt checkpoint rank cannot regress';
  end if;

  return new;
end
$$;

create trigger enforce_handoff_receipt_v2_insert
before insert on symphony_staging.handoff_receipts
for each row execute function symphony_staging.enforce_handoff_receipt_v2_insert();

create unique index handoff_receipts_checkpoint_identity_idx
  on symphony_staging.handoff_receipts (
    issue_id,
    claim_id,
    generation,
    checkpoint_kind,
    head_sha,
    coalesce(pr_number, 0)
  );

create index effect_operations_issue_operation_idx
  on symphony_staging.effect_operations (issue_id, operation_id);

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
  generation_receipt symphony_staging.handoff_receipts%rowtype;
  existing_receipt symphony_staging.handoff_receipts%rowtype;
  existing_receipt_found boolean;
  latest_receipt symphony_staging.handoff_receipts%rowtype;
  existing_pr_number bigint;
  requested_checkpoint_rank integer;
  latest_checkpoint_rank integer;
  inserted_receipt symphony_staging.handoff_receipts%rowtype;
begin
  if requested_issue_id is null
     or btrim(requested_issue_id) = ''
     or requested_repository is null
     or btrim(requested_repository) = ''
     or requested_branch is null
     or requested_branch !~ '[^[:space:]]'
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
       or item ->> 'name' !~ '[^[:space:]]'
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

  select receipts.*
  into generation_receipt
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
    and receipts.claim_id = requested_claim_id
    and receipts.generation = requested_generation
  order by receipts.checkpoint_sequence
  limit 1;

  if found and (
    generation_receipt.repository <> requested_repository
    or generation_receipt.branch <> requested_branch
    or generation_receipt.head_sha <> requested_head_sha
  ) then
    raise exception using errcode = '22023', message = 'handoff receipt generation is bound to another repository, branch, or head';
  end if;

  select min(receipts.pr_number)
  into existing_pr_number
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
    and receipts.claim_id = requested_claim_id
    and receipts.generation = requested_generation
    and receipts.pr_number is not null;

  if existing_pr_number is not null
     and requested_pr_number is not null
     and existing_pr_number <> requested_pr_number then
    raise exception using errcode = '22023', message = 'handoff receipt generation is bound to another pull request';
  end if;

  requested_checkpoint_rank := case requested_checkpoint_kind
    when 'pushed' then 1
    when 'pull_request' then 2
    when 'reviewed' then 3
  end;

  select receipts.*
  into existing_receipt
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
    and receipts.claim_id = requested_claim_id
    and receipts.generation = requested_generation
    and receipts.checkpoint_kind = requested_checkpoint_kind
    and receipts.head_sha = requested_head_sha
    and coalesce(receipts.pr_number, 0) = coalesce(requested_pr_number, 0)
  order by receipts.checkpoint_sequence
  limit 1;

  existing_receipt_found := found;

  if found then
    if existing_receipt.test_results <> requested_test_results then
      raise exception using errcode = '22023', message = 'handoff receipt retry identity has conflicting test results';
    end if;
  end if;

  select receipts.*
  into latest_receipt
  from symphony_staging.handoff_receipts receipts
  where receipts.issue_id = requested_issue_id
    and receipts.claim_id = requested_claim_id
    and receipts.generation = requested_generation
    and receipts.head_sha = requested_head_sha
  order by case receipts.checkpoint_kind
      when 'pushed' then 1
      when 'pull_request' then 2
      when 'reviewed' then 3
    end desc,
    receipts.checkpoint_sequence desc
  limit 1;

  if found then
    latest_checkpoint_rank := case latest_receipt.checkpoint_kind
      when 'pushed' then 1
      when 'pull_request' then 2
      when 'reviewed' then 3
    end;

    if latest_checkpoint_rank > requested_checkpoint_rank then
      return latest_receipt;
    end if;
  end if;

  if existing_receipt_found then
    return existing_receipt;
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
  'handoff-receipts', 2, '20260810000000_aro_166_handoff_retry_semantics'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

commit;
