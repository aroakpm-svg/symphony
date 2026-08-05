begin;

alter table symphony_staging.nodes
  add column claim_capacity integer not null default 1
    check (claim_capacity > 0);

create table symphony_staging.issue_claim_generations (
  issue_id text primary key,
  last_generation bigint not null default 0 check (last_generation >= 0)
);

create table symphony_staging.issue_claims (
  issue_id text primary key,
  claim_id uuid not null unique,
  generation bigint not null check (generation > 0),
  node_id uuid not null references symphony_staging.nodes(node_id) on delete restrict,
  node_instance_id uuid not null,
  linear_updated_at timestamptz not null,
  routing_policy text not null
    check (routing_policy in ('unassigned', 'preferred-with-fallback', 'exclusive')),
  target_node_id uuid references symphony_staging.nodes(node_id) on delete restrict,
  routing_revision bigint not null check (routing_revision > 0),
  claimed_at timestamptz not null,
  heartbeat_at timestamptz not null,
  lease_expires_at timestamptz not null,
  completed_at timestamptz,
  released_at timestamptz,
  check (completed_at is null or released_at is null)
);

create index issue_claims_active_node_idx
  on symphony_staging.issue_claims (node_id, lease_expires_at)
  where completed_at is null and released_at is null;

create table symphony_staging.claim_audit_events (
  audit_id bigint generated always as identity primary key,
  issue_id text not null,
  claim_id uuid,
  generation bigint,
  node_id uuid,
  node_instance_id uuid,
  event_type text not null
    check (event_type in ('claim', 'renew', 'release', 'complete', 'takeover', 'reject')),
  result text not null check (result in ('accepted', 'rejected')),
  reason_code text not null,
  occurred_at timestamptz not null default clock_timestamp()
);

alter table symphony_staging.issue_claim_generations enable row level security;
alter table symphony_staging.issue_claims enable row level security;
alter table symphony_staging.claim_audit_events enable row level security;

revoke all on table
  symphony_staging.issue_claim_generations,
  symphony_staging.issue_claims,
  symphony_staging.claim_audit_events
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

revoke all on sequence symphony_staging.claim_audit_events_audit_id_seq
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.routing_authorizes_node(
  requested_policy text,
  requested_target_node_id uuid,
  requested_node_id uuid
)
returns boolean
language sql
immutable
security invoker
set search_path = pg_catalog, pg_temp
as $$
  select requested_policy = 'unassigned'
      or requested_policy = 'preferred-with-fallback'
      or (requested_policy = 'exclusive' and requested_target_node_id = requested_node_id)
$$;

revoke all on function symphony_staging.routing_authorizes_node(text, uuid, uuid)
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.claim_issue(
  requested_issue_id text,
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
declare
  db_now timestamptz := clock_timestamp();
  route symphony_staging.routing_assignments%rowtype;
  current_claim symphony_staging.issue_claims%rowtype;
  last_generation bigint;
  active_count integer;
  node_capacity integer;
  next_generation bigint;
  next_claim_id uuid;
  event_type text := 'claim';
begin
  if requested_issue_id is null or btrim(requested_issue_id) = ''
     or requested_node_id is null or requested_node_instance_id is null
     or requested_linear_updated_at is null then
    raise exception using errcode = '22023', message = 'complete claim identity and Linear revision are required';
  end if;

  if requested_active_states is null
     or cardinality(requested_active_states) = 0
     or not (requested_issue_state = any(requested_active_states)) then
    raise exception using errcode = '55000', message = 'issue state is not claimable';
  end if;

  if requested_lease_ms <= 0 or requested_fallback_grace_ms < 0 then
    raise exception using errcode = '22023', message = 'invalid lease or fallback duration';
  end if;

  select nodes.claim_capacity
    into node_capacity
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals
    on principals.node_id = nodes.node_id
   and principals.login_role = session_user
   and principals.revoked_at is null
  join symphony_staging.active_node_instances instances
    on instances.node_id = nodes.node_id
   and instances.node_instance_id = requested_node_instance_id
  where nodes.node_id = requested_node_id
    and nodes.status = 'active'
  for update of nodes;

  if node_capacity is null then
    raise exception using errcode = '28000', message = 'node instance is not active';
  end if;

  select assignments.* into route
  from symphony_staging.routing_assignments assignments
  where assignments.issue_id = requested_issue_id
  for share;

  if route.issue_id is null then
    raise exception using errcode = '55000', message = 'routing snapshot is missing';
  end if;

  insert into symphony_staging.issue_claim_generations (issue_id)
  values (requested_issue_id)
  on conflict (issue_id) do nothing;

  select counters.last_generation into last_generation
  from symphony_staging.issue_claim_generations counters
  where counters.issue_id = requested_issue_id
  for update;

  select claims.* into current_claim
  from symphony_staging.issue_claims claims
  where claims.issue_id = requested_issue_id
  for update;

  if current_claim.issue_id is not null
     and current_claim.completed_at is null
     and current_claim.released_at is null
     and current_claim.lease_expires_at > db_now then
    if current_claim.node_id = requested_node_id
       and current_claim.node_instance_id = requested_node_instance_id then
      if route.routing_policy is distinct from current_claim.routing_policy
         or route.target_node_id is distinct from current_claim.target_node_id
         or route.routing_revision is distinct from current_claim.routing_revision
         or requested_linear_updated_at is distinct from current_claim.linear_updated_at
         or not symphony_staging.routing_authorizes_node(
           route.routing_policy, route.target_node_id, requested_node_id
         ) then
        raise exception using errcode = '55000', message = 'existing claim routing or Linear revision is stale';
      end if;

      update symphony_staging.issue_claims claims
      set heartbeat_at = db_now,
          lease_expires_at = db_now + make_interval(secs => requested_lease_ms / 1000.0)
      where claims.issue_id = requested_issue_id;

      return query select current_claim.claim_id, current_claim.generation;
      return;
    end if;

    raise exception using errcode = '55P03', message = 'issue already has an active claim';
  end if;

  if requested_issue_state = 'in progress' and current_claim.issue_id is null then
    raise exception using errcode = '55000', message = 'In Progress requires an expired claim takeover';
  end if;

  if not symphony_staging.routing_authorizes_node(
    route.routing_policy, route.target_node_id, requested_node_id
  ) then
    raise exception using errcode = '42501', message = 'exclusive route rejects this node';
  end if;

  if route.routing_policy = 'preferred-with-fallback'
     and route.target_node_id <> requested_node_id then
    if current_claim.issue_id is null then
      if db_now < route.updated_at + make_interval(secs => requested_fallback_grace_ms / 1000.0) then
        raise exception using errcode = '55P03', message = 'preferred target grace has not elapsed';
      end if;
    elsif db_now < current_claim.lease_expires_at then
      raise exception using errcode = '55P03', message = 'preferred owner lease has not expired';
    end if;
  end if;

  select count(*) into active_count
  from symphony_staging.issue_claims claims
  where claims.node_id = requested_node_id
    and claims.issue_id <> requested_issue_id
    and claims.completed_at is null
    and claims.released_at is null
    and claims.lease_expires_at > db_now;

  if active_count >= node_capacity then
    raise exception using errcode = '53300', message = 'node claim capacity exhausted';
  end if;

  next_generation := last_generation + 1;
  next_claim_id := gen_random_uuid();
  if current_claim.issue_id is not null then event_type := 'takeover'; end if;

  update symphony_staging.issue_claim_generations counters
  set last_generation = next_generation
  where counters.issue_id = requested_issue_id;

  insert into symphony_staging.issue_claims (
    issue_id, claim_id, generation, node_id, node_instance_id,
    linear_updated_at, routing_policy, target_node_id, routing_revision,
    claimed_at, heartbeat_at, lease_expires_at, completed_at, released_at
  ) values (
    requested_issue_id, next_claim_id, next_generation, requested_node_id,
    requested_node_instance_id, requested_linear_updated_at, route.routing_policy,
    route.target_node_id, route.routing_revision, db_now, db_now,
    db_now + make_interval(secs => requested_lease_ms / 1000.0), null, null
  )
  on conflict (issue_id) do update set
    claim_id = excluded.claim_id,
    generation = excluded.generation,
    node_id = excluded.node_id,
    node_instance_id = excluded.node_instance_id,
    linear_updated_at = excluded.linear_updated_at,
    routing_policy = excluded.routing_policy,
    target_node_id = excluded.target_node_id,
    routing_revision = excluded.routing_revision,
    claimed_at = excluded.claimed_at,
    heartbeat_at = excluded.heartbeat_at,
    lease_expires_at = excluded.lease_expires_at,
    completed_at = null,
    released_at = null;

  insert into symphony_staging.claim_audit_events (
    issue_id, claim_id, generation, node_id, node_instance_id,
    event_type, result, reason_code
  ) values (
    requested_issue_id, next_claim_id, next_generation, requested_node_id,
    requested_node_instance_id, event_type, 'accepted',
    case when event_type = 'takeover' then 'expired-lease-takeover' else 'new-claim' end
  );

  return query select next_claim_id, next_generation;
end
$$;

create or replace function symphony_staging.renew_claim(
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_lease_ms integer
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  db_now timestamptz := clock_timestamp();
  changed integer;
begin
  if requested_lease_ms <= 0 then return false; end if;

  perform 1
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals
    on principals.node_id = nodes.node_id
   and principals.login_role = session_user
   and principals.revoked_at is null
  join symphony_staging.active_node_instances instances
    on instances.node_id = nodes.node_id
   and instances.node_instance_id = requested_node_instance_id
  where nodes.node_id = requested_node_id and nodes.status = 'active'
  for update of nodes;

  if not found then return false; end if;

  update symphony_staging.issue_claims claims
  set heartbeat_at = db_now,
      lease_expires_at = db_now + make_interval(secs => requested_lease_ms / 1000.0)
  where claims.claim_id = requested_claim_id
    and claims.generation = requested_generation
    and claims.node_id = requested_node_id
    and claims.node_instance_id = requested_node_instance_id
    and exists (
      select 1
      from symphony_staging.routing_assignments assignments
      where assignments.issue_id = claims.issue_id
        and assignments.routing_policy = claims.routing_policy
        and assignments.target_node_id is not distinct from claims.target_node_id
        and assignments.routing_revision = claims.routing_revision
        and symphony_staging.routing_authorizes_node(
          assignments.routing_policy, assignments.target_node_id, requested_node_id
        )
    )
    and claims.completed_at is null
    and claims.released_at is null
    and claims.lease_expires_at > db_now;
  get diagnostics changed = row_count;

  if changed = 1 then
    insert into symphony_staging.claim_audit_events (
      issue_id, claim_id, generation, node_id, node_instance_id,
      event_type, result, reason_code
    )
    select claims.issue_id, claims.claim_id, claims.generation, claims.node_id,
           claims.node_instance_id, 'renew', 'accepted', 'active-generation'
    from symphony_staging.issue_claims claims
    where claims.claim_id = requested_claim_id;
  end if;

  return changed = 1;
end
$$;

create or replace function symphony_staging.validate_active_claim(
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select exists (
    select 1
    from symphony_staging.issue_claims claims
    join symphony_staging.nodes nodes on nodes.node_id = claims.node_id
    join symphony_staging.node_login_principals principals
      on principals.node_id = nodes.node_id
     and principals.login_role = session_user
     and principals.revoked_at is null
    join symphony_staging.active_node_instances instances
      on instances.node_id = claims.node_id
     and instances.node_instance_id = claims.node_instance_id
    where claims.claim_id = requested_claim_id
      and claims.generation = requested_generation
      and claims.node_id = requested_node_id
      and claims.node_instance_id = requested_node_instance_id
      and nodes.status = 'active'
      and claims.completed_at is null
      and claims.released_at is null
      and claims.lease_expires_at > clock_timestamp()
  )
$$;

create or replace function symphony_staging.finish_claim(
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  finish_kind text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  changed integer;
begin
  if finish_kind not in ('release', 'complete') then return false; end if;
  if not symphony_staging.validate_active_claim(
    requested_claim_id, requested_generation, requested_node_id, requested_node_instance_id
  ) then return false; end if;

  update symphony_staging.issue_claims claims
  set completed_at = case when finish_kind = 'complete' then clock_timestamp() else null end,
      released_at = case when finish_kind = 'release' then clock_timestamp() else null end,
      lease_expires_at = clock_timestamp()
  where claims.claim_id = requested_claim_id
    and claims.generation = requested_generation
    and claims.node_id = requested_node_id
    and claims.node_instance_id = requested_node_instance_id;
  get diagnostics changed = row_count;

  if changed = 1 then
    insert into symphony_staging.claim_audit_events (
      issue_id, claim_id, generation, node_id, node_instance_id,
      event_type, result, reason_code
    )
    select claims.issue_id, claims.claim_id, claims.generation, claims.node_id,
           claims.node_instance_id, finish_kind, 'accepted', 'active-generation'
    from symphony_staging.issue_claims claims
    where claims.claim_id = requested_claim_id;
  end if;

  return changed = 1;
end
$$;

create or replace function symphony_staging.release_claim(
  requested_claim_id uuid, requested_generation bigint,
  requested_node_id uuid, requested_node_instance_id uuid
)
returns boolean language sql security definer
set search_path = pg_catalog, pg_temp
as $$
  select symphony_staging.finish_claim($1, $2, $3, $4, 'release')
$$;

create or replace function symphony_staging.complete_claim(
  requested_claim_id uuid, requested_generation bigint,
  requested_node_id uuid, requested_node_instance_id uuid
)
returns boolean language sql security definer
set search_path = pg_catalog, pg_temp
as $$
  select symphony_staging.finish_claim($1, $2, $3, $4, 'complete')
$$;

create or replace function symphony_staging.takeover_claim(
  requested_issue_id text,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_linear_updated_at timestamptz,
  requested_active_states text[],
  requested_lease_ms integer,
  requested_fallback_grace_ms integer
)
returns table (claim_id uuid, generation bigint)
language sql
security definer
set search_path = pg_catalog, pg_temp
as $$
  select * from symphony_staging.claim_issue(
    $1, $2, $3, $4, 'in progress', $5, $6, $7
  )
$$;

revoke all on function
  symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer),
  symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer),
  symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid),
  symphony_staging.finish_claim(uuid, bigint, uuid, uuid, text),
  symphony_staging.release_claim(uuid, bigint, uuid, uuid),
  symphony_staging.complete_claim(uuid, bigint, uuid, uuid),
  symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer)
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer),
  symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer),
  symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid),
  symphony_staging.release_claim(uuid, bigint, uuid, uuid),
  symphony_staging.complete_claim(uuid, bigint, uuid, uuid),
  symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer)
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
    'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer) to %I',
    new.login_role
  );
  return new;
end
$$;

revoke all on function symphony_staging.grant_claim_api_to_node_login()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop trigger if exists grant_claim_api_to_node_login
  on symphony_staging.node_login_principals;
create trigger grant_claim_api_to_node_login
after insert or update of login_role on symphony_staging.node_login_principals
for each row execute function symphony_staging.grant_claim_api_to_node_login();

do $$
declare
  principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals
  loop
    execute format(
      'grant execute on function '
      'symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer), '
      'symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer), '
      'symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.release_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.complete_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer) to %I',
      principal.login_role
    );
  end loop;
end
$$;

grant update (claim_capacity) on symphony_staging.nodes
  to symphony_staging_provisioner;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'cross-machine-claims', 1, '20260804000000_aro_164_cross_machine_claims'
)
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
