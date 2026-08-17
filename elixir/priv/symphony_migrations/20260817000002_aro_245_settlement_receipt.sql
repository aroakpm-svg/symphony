begin;

do $$
declare
  constraint_name text;
  function_definition text;
  updated_definition text;
begin
  select constraints.conname into constraint_name
  from pg_catalog.pg_constraint constraints
  where constraints.conrelid = 'symphony_staging.effect_operations'::regclass
    and constraints.contype = 'c'
    and pg_catalog.pg_get_constraintdef(constraints.oid) like '%effect_type%';

  execute format('alter table symphony_staging.effect_operations drop constraint %I', constraint_name);
  alter table symphony_staging.effect_operations
    add constraint effect_operations_effect_type_check check (effect_type in (
      'linear_comment', 'github_comment', 'git_commit', 'git_push',
      'github_pr_create', 'github_pr_update', 'linear_state',
      'linear_issue_create', 'github_review_thread_resolve', 'review_settlement_receipt'
    ));

  select pg_catalog.pg_get_functiondef(
    'symphony_staging.begin_effect(text,text,text,text,uuid,bigint,uuid,uuid,uuid,integer)'::regprocedure
  ) into function_definition;
  updated_definition := replace(
    function_definition,
    $needle$'linear_issue_create', 'github_review_thread_resolve'$needle$,
    $replacement$'linear_issue_create', 'github_review_thread_resolve',
    'review_settlement_receipt'$replacement$
  );
  if updated_definition = function_definition then
    raise exception 'begin_effect allowlist shape is incompatible with settlement receipt migration';
  end if;
  execute updated_definition;
end
$$;

create or replace function symphony_staging.list_effect_operations(
  requested_issue_id text, requested_claim_id uuid, requested_generation bigint,
  requested_node_id uuid, requested_node_instance_id uuid
)
returns table (
  operation_id text, effect_type text, request_fingerprint text, status text,
  native_resource jsonb, issue_id text, claim_id uuid, generation bigint
)
language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
begin
  if requested_issue_id is null or btrim(requested_issue_id) = ''
     or requested_claim_id is null or requested_generation is null or requested_generation <= 0
     or requested_node_id is null or requested_node_instance_id is null then
    raise exception using errcode = '22023', message = 'complete active claim identity is required';
  end if;
  perform 1 from symphony_staging.issue_claims claims
  join symphony_staging.nodes nodes on nodes.node_id = claims.node_id
  join symphony_staging.node_login_principals principals on principals.node_id = claims.node_id
    and principals.login_role = session_user and principals.revoked_at is null
  join symphony_staging.active_node_instances instances on instances.node_id = claims.node_id
    and instances.node_instance_id = claims.node_instance_id
  where claims.issue_id = requested_issue_id and claims.claim_id = requested_claim_id
    and claims.generation = requested_generation and claims.node_id = requested_node_id
    and claims.node_instance_id = requested_node_instance_id and nodes.status = 'active'
    and claims.completed_at is null and claims.released_at is null
    and claims.lease_expires_at > clock_timestamp() for update of claims;
  if not found then
    raise exception using errcode = '55000', message = 'effect readback requires a matching active claim generation';
  end if;
  return query select operations.operation_id, operations.effect_type,
    operations.request_fingerprint, operations.status, operations.native_resource,
    operations.issue_id, operations.claim_id, operations.generation
  from symphony_staging.effect_operations operations
  where operations.issue_id = requested_issue_id and (
    operations.status in ('pending', 'unknown') or
    (operations.status = 'succeeded' and operations.effect_type in (
      'github_comment', 'linear_issue_create', 'github_review_thread_resolve',
      'review_settlement_receipt'
    ))) and operations.generation <= requested_generation
  order by operations.operation_id;
end
$$;

insert into symphony_staging.contract_versions (contract_name, contract_version, migration_name)
values ('effect-ledger', 3, '20260817000002_aro_245_settlement_receipt'),
       ('finding-effect-readback', 3, '20260817000002_aro_245_settlement_receipt')
on conflict (contract_name) do update set contract_version = excluded.contract_version,
  migration_name = excluded.migration_name, installed_at = clock_timestamp();

commit;
