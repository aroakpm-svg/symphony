begin;

do $$
begin
  if not exists (
    select 1
    from symphony_staging.contract_versions
    where contract_name = 'cross-machine-claims'
  ) then
    raise exception using
      errcode = '55000',
      message = 'cross-machine-claims contract is required';
  end if;
end
$$;

create or replace function symphony_staging.current_node_claim_capacity()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  matching_nodes integer;
  capacity integer;
begin
  -- select nodes.claim_capacity through min while enforcing one identity.
  select count(*), min(nodes.claim_capacity)
    into matching_nodes, capacity
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes on nodes.node_id = principals.node_id
  where principals.login_role = session_user
    and principals.revoked_at is null
    and nodes.status = 'active';

  if matching_nodes <> 1 then
    raise exception using errcode = '28000', message = 'node capacity identity rejected';
  end if;

  return capacity;
end
$$;

revoke all on function symphony_staging.current_node_claim_capacity()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.grant_claim_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer), '
    'symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer), '
    'symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.release_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.complete_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer), '
    'symphony_staging.current_node_claim_capacity() to %I',
    new.login_role
  );
  return new;
end
$$;

do $$
declare
  principal record;
begin
  for principal in
    select login_role
    from symphony_staging.node_login_principals
    where revoked_at is null
  loop
    execute format(
      'grant execute on function symphony_staging.current_node_claim_capacity() to %I',
      principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'node-capacity-contract', 1, '20260827000000_aro_288_node_capacity_contract'
)
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
