begin;

create or replace function symphony_staging.list_effect_operations(
  requested_issue_id text,
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns table (
  operation_id text,
  effect_type text,
  request_fingerprint text,
  status text,
  native_resource jsonb,
  issue_id text,
  claim_id uuid,
  generation bigint
)
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if requested_issue_id is null or btrim(requested_issue_id) = ''
     or requested_claim_id is null
     or requested_generation is null or requested_generation <= 0
     or requested_node_id is null
     or requested_node_instance_id is null then
    raise exception using errcode = '22023',
      message = 'complete active claim identity is required';
  end if;

  perform 1
  from symphony_staging.issue_claims claims
  join symphony_staging.nodes nodes
    on nodes.node_id = claims.node_id
  join symphony_staging.node_login_principals principals
    on principals.node_id = claims.node_id
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
      message = 'effect readback requires a matching active claim generation';
  end if;

  return query
  select operations.operation_id,
         operations.effect_type,
         operations.request_fingerprint,
         operations.status,
         operations.native_resource,
         operations.issue_id,
         operations.claim_id,
         operations.generation
  from symphony_staging.effect_operations operations
  where operations.issue_id = requested_issue_id
    and (
      operations.status in ('pending', 'unknown')
      or (
        operations.status = 'succeeded'
        and operations.effect_type in (
          'github_comment', 'linear_issue_create', 'github_review_thread_resolve'
        )
      )
    )
    and operations.generation <= requested_generation
  order by operations.operation_id;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'finding-effect-readback', 2, '20260817000001_aro_245_durable_settlement_readback'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

commit;
