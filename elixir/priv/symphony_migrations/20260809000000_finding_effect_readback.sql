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
    and operations.status in ('pending', 'unknown')
    and operations.generation <= requested_generation
  order by operations.operation_id;
end
$$;

revoke all on table symphony_staging.effect_operations
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

revoke all on function
  symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid)
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid)
  to symphony_staging_runtime;

create or replace function symphony_staging.grant_finding_readback_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid) to %I',
    new.login_role
  );
  return new;
end
$$;

revoke all on function symphony_staging.grant_finding_readback_api_to_node_login()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop trigger if exists grant_finding_readback_api_to_node_login
  on symphony_staging.node_login_principals;
create trigger grant_finding_readback_api_to_node_login
after insert or update of login_role on symphony_staging.node_login_principals
for each row execute function symphony_staging.grant_finding_readback_api_to_node_login();

do $$
declare
  principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals
    where revoked_at is null
  loop
    execute format(
      'grant execute on function '
      'symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid) to %I',
      principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'finding-effect-readback', 1, '20260809000000_finding_effect_readback'
)
on conflict (contract_name) do update
set contract_version = excluded.contract_version,
    migration_name = excluded.migration_name,
    installed_at = clock_timestamp();

commit;
