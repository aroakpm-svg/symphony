begin;

create schema if not exists symphony_staging;

create temporary table if not exists aro_163_created_roles (
  role_name name primary key
) on commit drop;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'symphony_staging_runtime') then
    create role symphony_staging_runtime
      nologin
      nosuperuser
      nocreatedb
      nocreaterole
      noinherit
      noreplication
      nobypassrls;
    insert into aro_163_created_roles values ('symphony_staging_runtime');
  end if;

  if not exists (select 1 from pg_roles where rolname = 'symphony_staging_provisioner') then
    create role symphony_staging_provisioner
      nologin
      nosuperuser
      nocreatedb
      nocreaterole
      noinherit
      noreplication
      nobypassrls;
    insert into aro_163_created_roles values ('symphony_staging_provisioner');
  end if;
end
$$;

do $$
declare
  role_name name;
  role_record record;
  postgres_oid oid := (select oid from pg_roles where rolname = 'postgres');
begin
  foreach role_name in array array[
    'symphony_staging_runtime'::name,
    'symphony_staging_provisioner'::name
  ]
  loop
    select *
    into strict role_record
    from pg_roles
    where rolname = role_name;

    if role_record.rolconfig is not null
       or exists (
         select 1
         from pg_auth_members memberships
         where (
           memberships.roleid = role_record.oid
           and memberships.member <> postgres_oid
         )
         or memberships.member = role_record.oid
       ) then
      raise exception using
        errcode = '42501',
        message = format('unsafe pre-existing role state for %I', role_name);
    end if;

    if not exists (
         select 1
         from aro_163_created_roles created
         where created.role_name = role_name
       )
       and (
         not has_schema_privilege(role_name, 'symphony_staging', 'USAGE')
         or has_schema_privilege(role_name, 'symphony_staging', 'CREATE')
         or has_schema_privilege(
           role_name,
           'symphony_staging',
           'USAGE WITH GRANT OPTION'
         )
       ) then
      raise exception using
        errcode = '42501',
        message = format('incompatible pre-existing schema grants for %I', role_name);
    end if;
  end loop;
end
$$;

alter role symphony_staging_runtime with
  nologin
  nosuperuser
  nocreatedb
  nocreaterole
  noinherit
  noreplication
  nobypassrls;
alter role symphony_staging_provisioner with
  nologin
  nosuperuser
  nocreatedb
  nocreaterole
  noinherit
  noreplication
  nobypassrls;

grant symphony_staging_runtime, symphony_staging_provisioner to postgres;

revoke all on schema symphony_staging
  from symphony_staging_runtime, symphony_staging_provisioner;

grant usage on schema symphony_staging
  to symphony_staging_runtime, symphony_staging_provisioner;

create table if not exists symphony_staging.contract_versions (
  contract_name text primary key,
  contract_version integer not null check (contract_version > 0),
  migration_name text not null,
  installed_at timestamptz not null default clock_timestamp()
);

create table if not exists symphony_staging.nodes (
  node_id uuid primary key,
  display_alias text,
  status text not null
    check (status in ('active', 'disabled', 'retired')),
  credential_version integer not null default 1
    check (credential_version > 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  rotated_at timestamptz,
  revoked_at timestamptz,
  retired_at timestamptz,
  check (status <> 'active' or (revoked_at is null and retired_at is null)),
  check (status <> 'disabled' or (revoked_at is not null and retired_at is null)),
  check (status <> 'retired' or retired_at is not null)
);

create table if not exists symphony_staging.node_bindings (
  binding_id uuid primary key,
  node_id uuid not null
    references symphony_staging.nodes(node_id) on delete restrict,
  environment text not null check (environment = 'staging'),
  status text not null
    check (status in ('pending', 'active', 'rotating', 'revoked', 'retired')),
  credential_version integer not null check (credential_version > 0),
  credential_verifier text not null
    check (credential_verifier ~ '^[A-Fa-f0-9]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  activated_at timestamptz,
  rotated_at timestamptz,
  revoked_at timestamptz,
  retired_at timestamptz,
  check (status <> 'active' or activated_at is not null),
  check (status <> 'rotating' or rotated_at is not null),
  check (status <> 'revoked' or revoked_at is not null),
  check (status <> 'retired' or retired_at is not null),
  unique (node_id, environment, credential_version)
);

create unique index if not exists node_bindings_one_active_per_node
  on symphony_staging.node_bindings (node_id, environment)
  where status = 'active';

create unique index if not exists node_bindings_one_rotating_per_node
  on symphony_staging.node_bindings (node_id, environment)
  where status = 'rotating';

create table if not exists symphony_staging.routing_assignments (
  issue_id text primary key,
  routing_policy text not null
    check (routing_policy in ('unassigned', 'preferred-with-fallback', 'exclusive')),
  target_node_id uuid
    references symphony_staging.nodes(node_id) on delete restrict,
  routing_revision bigint not null check (routing_revision > 0),
  contract_version integer not null check (contract_version > 0),
  updated_at timestamptz not null default clock_timestamp(),
  check (
    (routing_policy = 'unassigned' and target_node_id is null)
    or
    (routing_policy in ('preferred-with-fallback', 'exclusive') and target_node_id is not null)
  )
);

create index if not exists routing_assignments_target_node_id_idx
  on symphony_staging.routing_assignments (target_node_id);

create table if not exists symphony_staging.foundation_audit_events (
  audit_id bigint generated always as identity primary key,
  event_type text not null,
  node_id uuid,
  binding_id uuid,
  issue_id text,
  routing_revision bigint,
  credential_version integer,
  result text not null check (result in ('accepted', 'rejected', 'unknown')),
  reason_code text not null,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),
  check (jsonb_typeof(details) = 'object')
);

comment on column symphony_staging.node_bindings.credential_verifier is
  'SHA-256 verifier only. Never store the node credential itself.';
comment on table symphony_staging.routing_assignments is
  'Routing foundation only. Atomic claim, fallback, lease, and generation belong to ARO-164.';
comment on table symphony_staging.foundation_audit_events is
  'Masked foundation audit. Secrets, hostnames, personal paths, and full machine identifiers are forbidden.';

create or replace function symphony_staging.enforce_node_transition()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, symphony_staging
as $$
begin
  if new.node_id <> old.node_id then
    raise exception using
      errcode = '23514',
      message = 'node_id is immutable';
  end if;

  if new.credential_version < old.credential_version then
    raise exception using
      errcode = '23514',
      message = 'credential_version cannot decrease';
  end if;

  if old.status = 'retired' and new.status <> 'retired' then
    raise exception using
      errcode = '23514',
      message = 'retired node cannot become active';
  end if;

  return new;
end
$$;

drop trigger if exists enforce_node_transition
  on symphony_staging.nodes;
create trigger enforce_node_transition
before update on symphony_staging.nodes
for each row execute function symphony_staging.enforce_node_transition();

create or replace function symphony_staging.enforce_node_binding_transition()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, symphony_staging
as $$
declare
  transition text := old.status || '->' || new.status;
begin
  if new.binding_id <> old.binding_id
     or new.node_id <> old.node_id
     or new.environment <> old.environment
     or new.credential_version <> old.credential_version
     or new.credential_verifier <> old.credential_verifier then
    raise exception using
      errcode = '23514',
      message = 'binding identity and verifier are immutable';
  end if;

  if new.status <> old.status
     and transition not in (
       'pending->active',
       'pending->revoked',
       'pending->retired',
       'active->rotating',
       'active->revoked',
       'active->retired',
       'rotating->active',
       'rotating->revoked',
       'rotating->retired',
       'revoked->retired'
     ) then
    raise exception using
      errcode = '23514',
      message = 'invalid node binding transition';
  end if;

  return new;
end
$$;

drop trigger if exists enforce_node_binding_transition
  on symphony_staging.node_bindings;
create trigger enforce_node_binding_transition
before update on symphony_staging.node_bindings
for each row execute function symphony_staging.enforce_node_binding_transition();

create or replace function symphony_staging.enforce_routing_revision()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog, symphony_staging
as $$
begin
  if new.issue_id <> old.issue_id then
    raise exception using
      errcode = '23514',
      message = 'issue_id is immutable';
  end if;

  if new.routing_revision <= old.routing_revision then
    raise exception using
      errcode = '23514',
      message = 'routing_revision must increase';
  end if;

  return new;
end
$$;

drop trigger if exists enforce_routing_revision
  on symphony_staging.routing_assignments;
create trigger enforce_routing_revision
before update on symphony_staging.routing_assignments
for each row execute function symphony_staging.enforce_routing_revision();

alter table symphony_staging.contract_versions enable row level security;
alter table symphony_staging.nodes enable row level security;
alter table symphony_staging.node_bindings enable row level security;
alter table symphony_staging.routing_assignments enable row level security;
alter table symphony_staging.foundation_audit_events enable row level security;

drop policy if exists runtime_read_contract_versions
  on symphony_staging.contract_versions;
create policy runtime_read_contract_versions
  on symphony_staging.contract_versions
  for select
  to symphony_staging_runtime
  using (true);

drop policy if exists runtime_read_nodes
  on symphony_staging.nodes;
create policy runtime_read_nodes
  on symphony_staging.nodes
  for select
  to symphony_staging_runtime
  using (true);

drop policy if exists runtime_read_node_bindings
  on symphony_staging.node_bindings;
create policy runtime_read_node_bindings
  on symphony_staging.node_bindings
  for select
  to symphony_staging_runtime
  using (true);

drop policy if exists runtime_read_routing_assignments
  on symphony_staging.routing_assignments;
create policy runtime_read_routing_assignments
  on symphony_staging.routing_assignments
  for select
  to symphony_staging_runtime
  using (true);

drop policy if exists runtime_insert_audit_events
  on symphony_staging.foundation_audit_events;
create policy runtime_insert_audit_events
  on symphony_staging.foundation_audit_events
  for insert
  to symphony_staging_runtime
  with check (true);

drop policy if exists provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
create policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions
  for all
  to symphony_staging_provisioner
  using (contract_name not like 'aro-163-created-role:%')
  with check (contract_name not like 'aro-163-created-role:%');

drop policy if exists provisioner_manage_nodes
  on symphony_staging.nodes;
create policy provisioner_manage_nodes
  on symphony_staging.nodes
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);

drop policy if exists provisioner_manage_node_bindings
  on symphony_staging.node_bindings;
create policy provisioner_manage_node_bindings
  on symphony_staging.node_bindings
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);

drop policy if exists provisioner_manage_routing_assignments
  on symphony_staging.routing_assignments;
create policy provisioner_manage_routing_assignments
  on symphony_staging.routing_assignments
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);

drop policy if exists provisioner_insert_audit_events
  on symphony_staging.foundation_audit_events;
create policy provisioner_insert_audit_events
  on symphony_staging.foundation_audit_events
  for insert
  to symphony_staging_provisioner
  with check (true);

revoke all on table
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments,
  symphony_staging.foundation_audit_events
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
revoke all on sequence
  symphony_staging.foundation_audit_events_audit_id_seq
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
revoke execute on function
  symphony_staging.enforce_node_transition(),
  symphony_staging.enforce_node_binding_transition(),
  symphony_staging.enforce_routing_revision()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

grant select on symphony_staging.contract_versions
  to symphony_staging_runtime;
grant select (
  node_id,
  display_alias,
  status,
  credential_version,
  created_at,
  updated_at,
  rotated_at,
  revoked_at,
  retired_at
) on symphony_staging.nodes
  to symphony_staging_runtime;
grant select (
  binding_id,
  node_id,
  environment,
  status,
  credential_version,
  created_at,
  activated_at,
  rotated_at,
  revoked_at,
  retired_at
) on symphony_staging.node_bindings
  to symphony_staging_runtime;
grant select on symphony_staging.routing_assignments
  to symphony_staging_runtime;
grant insert (
  event_type,
  node_id,
  binding_id,
  issue_id,
  routing_revision,
  credential_version,
  result,
  reason_code,
  details
) on symphony_staging.foundation_audit_events
  to symphony_staging_runtime;
grant usage, select on sequence symphony_staging.foundation_audit_events_audit_id_seq
  to symphony_staging_runtime;

grant select, insert, update on
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments
  to symphony_staging_provisioner;
grant insert on symphony_staging.foundation_audit_events
  to symphony_staging_provisioner;
grant usage, select on sequence symphony_staging.foundation_audit_events_audit_id_seq
  to symphony_staging_provisioner;

insert into symphony_staging.contract_versions (
  contract_name,
  contract_version,
  migration_name
)
values (
  'node-identity-routing-foundation',
  1,
  '20260723000000_aro_163_staging_foundation'
)
on conflict (contract_name) do update
set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name;

insert into symphony_staging.contract_versions (
  contract_name,
  contract_version,
  migration_name
)
select
  'aro-163-created-role:' || role_name,
  1,
  '20260723000000_aro_163_staging_foundation'
from aro_163_created_roles
on conflict (contract_name) do nothing;

commit;
