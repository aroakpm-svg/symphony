begin;

do $$
begin
  if not exists (
    select 1 from symphony_staging.contract_versions
    where contract_name = 'cross-machine-claims'
  ) then
    raise exception using errcode = '55000', message = 'cross-machine-claims contract is required';
  end if;
end
$$;

create or replace function symphony_staging.exclusive_route_snapshot(requested_issue_id text)
returns table (routing_policy text, target_node_id uuid, routing_revision bigint)
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  matching_nodes integer;
  authenticated_node_id uuid;
begin
  select count(*), min(principals.node_id)
    into matching_nodes, authenticated_node_id
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes on nodes.node_id = principals.node_id
  where principals.login_role = session_user
    and principals.revoked_at is null
    and nodes.status = 'active';

  if matching_nodes <> 1 then
    raise exception using errcode = '28000', message = 'node routing identity rejected';
  end if;

  return query
  select assignments.routing_policy, assignments.target_node_id, assignments.routing_revision
  from symphony_staging.routing_assignments assignments
  where assignments.issue_id = requested_issue_id
    and assignments.routing_policy = 'exclusive'
    and assignments.target_node_id = authenticated_node_id;
end
$$;

create or replace function symphony_staging.claim_exclusive_issue(
  requested_issue_id text,
  expected_routing_revision bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_linear_updated_at timestamptz,
  requested_issue_state text,
  requested_active_states text[],
  requested_lease_ms integer,
  requested_fallback_grace_ms integer
)
returns table (claim_id uuid, generation bigint)
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  perform 1
  from symphony_staging.routing_assignments assignments
  join symphony_staging.node_login_principals principals
    on principals.node_id = requested_node_id
   and principals.login_role = session_user
   and principals.revoked_at is null
  join symphony_staging.nodes nodes
    on nodes.node_id = principals.node_id
   and nodes.status = 'active'
  where assignments.issue_id = requested_issue_id
    and assignments.routing_policy = 'exclusive'
    and assignments.target_node_id = requested_node_id
    and assignments.routing_revision = expected_routing_revision
  for share of assignments;

  if not found then
    raise exception using errcode = '55000', message = 'exclusive routing receipt is stale';
  end if;

  return query
  select * from symphony_staging.claim_issue(
    requested_issue_id, requested_node_id, requested_node_instance_id,
    requested_linear_updated_at, requested_issue_state, requested_active_states,
    requested_lease_ms, requested_fallback_grace_ms
  );
end
$$;

revoke all on function
  symphony_staging.exclusive_route_snapshot(text),
  symphony_staging.claim_exclusive_issue(text, bigint, uuid, uuid, timestamptz, text, text[], integer, integer)
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.exclusive_route_snapshot(text),
  symphony_staging.claim_exclusive_issue(text, bigint, uuid, uuid, timestamptz, text, text[], integer, integer)
  to symphony_staging_runtime;

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
    'symphony_staging.current_node_claim_capacity(), '
    'symphony_staging.exclusive_route_snapshot(text), '
    'symphony_staging.claim_exclusive_issue(text, bigint, uuid, uuid, timestamptz, text, text[], integer, integer) to %I',
    new.login_role
  );
  return new;
end
$$;

do $$
declare principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals where revoked_at is null
  loop
    execute format(
      'grant execute on function symphony_staging.exclusive_route_snapshot(text), '
      'symphony_staging.claim_exclusive_issue(text, bigint, uuid, uuid, timestamptz, text, text[], integer, integer) to %I',
      principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (contract_name, contract_version, migration_name)
values ('exclusive-route-claim-api', 1, '20260828000000_aro_287_exclusive_route_claim_api')
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
