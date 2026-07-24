begin;

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('aroak:symphony_staging:migrations', 0)
);

do $$
begin
  if not exists (
    select 1
    from symphony_staging.contract_versions
    where contract_name = 'node-identity-routing-foundation'
      and contract_version = 2
      and migration_name = '20260724000000_aro_168_staging_reconciliation'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 requires the reconciled ARO-168 contract v2';
  end if;
end
$$;

create table symphony_staging.node_login_principals (
  node_id uuid primary key
    references symphony_staging.nodes(node_id) on delete restrict,
  login_role name not null unique,
  created_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);

alter table symphony_staging.node_login_principals enable row level security;

create policy provisioner_manage_node_login_principals
  on symphony_staging.node_login_principals
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);

revoke all on table symphony_staging.node_login_principals
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
grant select, insert, update on symphony_staging.node_login_principals
  to symphony_staging_provisioner;

create table symphony_staging.node_instance_history (
  node_id uuid not null
    references symphony_staging.node_login_principals(node_id) on delete restrict,
  node_instance_id uuid not null,
  authenticated_at timestamptz not null default clock_timestamp(),
  primary key (node_id, node_instance_id)
);

create table symphony_staging.active_node_instances (
  node_id uuid primary key
    references symphony_staging.node_login_principals(node_id) on delete restrict,
  node_instance_id uuid not null,
  authenticated_at timestamptz not null default clock_timestamp(),
  unique (node_id, node_instance_id)
);

create table symphony_staging.node_enrollment_contract_manifest (
  singleton boolean primary key default true check (singleton),
  expected_fingerprint text not null,
  recorded_at timestamptz not null default clock_timestamp()
);

alter table symphony_staging.node_instance_history enable row level security;
alter table symphony_staging.active_node_instances enable row level security;
alter table symphony_staging.node_enrollment_contract_manifest enable row level security;

revoke all on table
  symphony_staging.node_instance_history,
  symphony_staging.active_node_instances,
  symphony_staging.node_enrollment_contract_manifest
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.provision_node(
  requested_display_alias text
)
returns table (
  node_id uuid,
  binding_id uuid,
  login_role name,
  node_credential text,
  contract_version integer
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  generated_node_id uuid := gen_random_uuid();
  generated_binding_id uuid := gen_random_uuid();
  generated_login_role name :=
    ('symphony_node_' || replace(generated_node_id::text, '-', ''))::name;
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'USAGE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 provisioning requires the staging provisioner';
  end if;

  if requested_display_alias is null
     or btrim(requested_display_alias) = ''
     or length(requested_display_alias) > 120 then
    raise exception using
      errcode = '22023',
      message = 'display alias must contain 1 to 120 characters';
  end if;

  execute format(
    'create role %I login password %L nosuperuser nocreatedb ' ||
    'nocreaterole noinherit noreplication nobypassrls',
    generated_login_role,
    generated_credential
  );

  execute format(
    'alter role %I set search_path = pg_catalog, symphony_staging',
    generated_login_role
  );

  execute format(
    'grant usage on schema symphony_staging to %I',
    generated_login_role
  );

  execute format(
    'grant execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) to %I',
    generated_login_role
  );

  insert into symphony_staging.nodes (
    node_id,
    display_alias,
    status,
    credential_version
  )
  values (
    generated_node_id,
    btrim(requested_display_alias),
    'active',
    1
  );

  insert into symphony_staging.node_bindings (
    binding_id,
    node_id,
    environment,
    status,
    credential_version,
    credential_verifier,
    activated_at
  )
  values (
    generated_binding_id,
    generated_node_id,
    'staging',
    'active',
    1,
    generated_verifier,
    clock_timestamp()
  );

  insert into symphony_staging.node_login_principals (
    node_id,
    login_role
  )
  values (
    generated_node_id,
    generated_login_role
  );

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    binding_id,
    credential_version,
    result,
    reason_code,
    details
  )
  values (
    'node_provisioned',
    generated_node_id,
    generated_binding_id,
    1,
    'accepted',
    'atomic_provisioning_complete',
    jsonb_build_object('environment', 'staging')
  );

  return query
  select
    generated_node_id,
    generated_binding_id,
    generated_login_role,
    generated_credential,
    3;
end
$$;

create or replace function symphony_staging.rotate_node_credential(
  requested_node_id uuid
)
returns table (
  node_id uuid,
  login_role name,
  node_credential text,
  credential_version integer,
  contract_version integer
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  principal_role name;
  replacement_role name;
  generated_binding_id uuid := gen_random_uuid();
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
  next_credential_version integer;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'USAGE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 rotation requires the staging provisioner';
  end if;

  select principals.login_role, nodes.credential_version + 1
  into principal_role, next_credential_version
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes using (node_id)
  where principals.node_id = requested_node_id
    and principals.revoked_at is null
    and nodes.status = 'active'
  for update of nodes, principals;

  if principal_role is null then
    raise exception using
      errcode = '02000',
      message = 'active node not found';
  end if;

  replacement_role :=
    ('symphony_node_' ||
      replace(requested_node_id::text, '-', '') ||
      '_v' || next_credential_version::text)::name;

  execute format(
    'create role %I login password %L nosuperuser nocreatedb ' ||
    'nocreaterole noinherit noreplication nobypassrls',
    replacement_role,
    generated_credential
  );

  execute format(
    'alter role %I set search_path = pg_catalog, symphony_staging',
    replacement_role
  );
  execute format(
    'grant usage on schema symphony_staging to %I',
    replacement_role
  );
  execute format(
    'grant execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) to %I',
    replacement_role
  );

  execute format('alter role %I nologin', principal_role);
  execute format(
    'revoke execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) from %I',
    principal_role
  );
  execute format(
    'revoke usage on schema symphony_staging from %I',
    principal_role
  );

  update symphony_staging.node_bindings as bindings
  set
    status = 'revoked',
    revoked_at = clock_timestamp()
  where bindings.node_id = requested_node_id
    and bindings.environment = 'staging'
    and bindings.status = 'active';

  update symphony_staging.nodes as nodes
  set
    credential_version = next_credential_version,
    rotated_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id;

  delete from symphony_staging.active_node_instances as instances
  where instances.node_id = requested_node_id;

  update symphony_staging.node_login_principals as principals
  set login_role = replacement_role
  where principals.node_id = requested_node_id;

  insert into symphony_staging.node_bindings (
    binding_id,
    node_id,
    environment,
    status,
    credential_version,
    credential_verifier,
    activated_at
  )
  values (
    generated_binding_id,
    requested_node_id,
    'staging',
    'active',
    next_credential_version,
    generated_verifier,
    clock_timestamp()
  );

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    binding_id,
    credential_version,
    result,
    reason_code,
    details
  )
  values (
    'node_credential_rotated',
    requested_node_id,
    generated_binding_id,
    next_credential_version,
    'accepted',
    'credential_rotated',
    jsonb_build_object('environment', 'staging')
  );

  return query
  select
    requested_node_id,
    replacement_role,
    generated_credential,
    next_credential_version,
    3;
end
$$;

create or replace function symphony_staging.retire_node_instance(
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'USAGE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 instance retirement requires the staging provisioner';
  end if;

  perform 1
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals using (node_id)
  where nodes.node_id = requested_node_id
  for update of nodes, principals;

  delete from symphony_staging.active_node_instances instances
  where instances.node_id = requested_node_id
    and instances.node_instance_id = requested_node_instance_id;

  if not found then
    raise exception using
      errcode = '02000',
      message = 'active node instance not found';
  end if;

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_instance_retired',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'provisioner_confirmed_worker_stopped',
    jsonb_build_object(
      'node_instance_id', requested_node_instance_id,
      'environment', 'staging'
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;
end
$$;

create or replace function symphony_staging.revoke_node(
  requested_node_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  principal_role name;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'USAGE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 revocation requires the staging provisioner';
  end if;

  select principals.login_role
  into principal_role
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals using (node_id)
  where nodes.node_id = requested_node_id
    and nodes.status = 'active'
    and principals.revoked_at is null
  for update of nodes, principals;

  if principal_role is null then
    raise exception using
      errcode = '02000',
      message = 'active node principal not found';
  end if;

  execute format('alter role %I nologin', principal_role);

  execute format(
    'revoke execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) from %I',
    principal_role
  );

  execute format(
    'revoke usage on schema symphony_staging from %I',
    principal_role
  );

  update symphony_staging.node_bindings as bindings
  set
    status = 'revoked',
    revoked_at = clock_timestamp()
  where bindings.node_id = requested_node_id
    and bindings.environment = 'staging'
    and bindings.status = 'active';

  update symphony_staging.nodes as nodes
  set
    status = 'disabled',
    revoked_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id
    and status = 'active';

  update symphony_staging.node_login_principals as principals
  set revoked_at = clock_timestamp()
  where principals.node_id = requested_node_id;

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_revoked',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'credential_disabled',
    jsonb_build_object('environment', 'staging')
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;
end
$$;

create or replace function symphony_staging.authenticate_node(
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns table (
  node_id uuid,
  node_instance_id uuid,
  contract_version integer
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  authenticated_node_id uuid;
  claimed_node_id uuid;
begin
  if requested_node_id is null or requested_node_instance_id is null then
    raise exception using
      errcode = '22023',
      message = 'nodeId and nodeInstanceId are required';
  end if;

  select principals.node_id
  into authenticated_node_id
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes
    on nodes.node_id = principals.node_id
  join symphony_staging.node_bindings bindings
    on bindings.node_id = nodes.node_id
   and bindings.environment = 'staging'
   and bindings.status = 'active'
   and bindings.credential_version = nodes.credential_version
  where principals.node_id = requested_node_id
    and principals.login_role = session_user
    and principals.revoked_at is null
    and nodes.status = 'active'
  for update of nodes, principals, bindings;

  if authenticated_node_id is null then
    raise exception using
      errcode = '28000',
      message = 'node authentication rejected';
  end if;

  begin
    insert into symphony_staging.node_instance_history (
      node_id,
      node_instance_id
    )
    values (
      authenticated_node_id,
      requested_node_instance_id
    );
  exception
    when unique_violation then
      raise exception using
        errcode = '28000',
        message = 'node instance reuse rejected';
  end;

  insert into symphony_staging.active_node_instances (
    node_id,
    node_instance_id
  )
  values (
    authenticated_node_id,
    requested_node_instance_id
  )
  on conflict on constraint active_node_instances_pkey do nothing
  returning requested_node_id into claimed_node_id;

  if claimed_node_id is null then
    raise exception using
      errcode = '55006',
      message = 'duplicate node session rejected';
  end if;

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_authenticated',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'server_instance_claimed',
    jsonb_build_object(
      'node_instance_id',
      requested_node_instance_id,
      'environment',
      'staging'
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = authenticated_node_id;

  return query
  select authenticated_node_id, requested_node_instance_id, 3;
end
$$;

revoke execute on function
  symphony_staging.provision_node(text),
  symphony_staging.rotate_node_credential(uuid),
  symphony_staging.revoke_node(uuid),
  symphony_staging.retire_node_instance(uuid, uuid),
  symphony_staging.authenticate_node(uuid, uuid)
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

grant execute on function symphony_staging.provision_node(text)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.rotate_node_credential(uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.revoke_node(uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.retire_node_instance(uuid, uuid)
  to symphony_staging_provisioner;

insert into symphony_staging.node_enrollment_contract_manifest (
  expected_fingerprint
)
select md5(string_agg(signature, E'\n' order by signature))
from (
  select
    'function:' || procedure.oid::regprocedure::text || ':' ||
    pg_get_userbyid(procedure.proowner) || ':' ||
    coalesce(procedure.proacl::text, '') || ':' ||
    pg_get_functiondef(procedure.oid) as signature
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'symphony_staging'
    and procedure.proname in (
      'provision_node',
      'rotate_node_credential',
      'revoke_node',
      'retire_node_instance',
      'authenticate_node'
    )
  union all
  select
    'table:' || relation.relname || ':' ||
    pg_get_userbyid(relation.relowner) || ':' ||
    relation.relrowsecurity::text || ':' ||
    coalesce(relation.relacl::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest'
    )
  union all
  select
    'column:' || relation.relname || ':' || attribute.attname || ':' ||
    format_type(attribute.atttypid, attribute.atttypmod) || ':' ||
    attribute.attnotnull::text || ':' ||
    coalesce(pg_get_expr(default_value.adbin, default_value.adrelid), '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_attribute attribute on attribute.attrelid = relation.oid
  left join pg_attrdef default_value
    on default_value.adrelid = relation.oid
   and default_value.adnum = attribute.attnum
  where namespace.nspname = 'symphony_staging'
    and relation.relname like 'node\_%' escape '\'
    and attribute.attnum > 0
    and not attribute.attisdropped
  union all
  select
    'constraint:' || relation.relname || ':' || constraint_row.conname || ':' ||
    pg_get_constraintdef(constraint_row.oid, true)
  from pg_constraint constraint_row
  join pg_class relation on relation.oid = constraint_row.conrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest'
    )
  union all
  select
    'policy:' || schemaname || ':' || tablename || ':' || policyname || ':' ||
    permissive || ':' || roles::text || ':' || cmd || ':' ||
    coalesce(qual, '') || ':' || coalesce(with_check, '')
  from pg_policies
  where schemaname = 'symphony_staging'
    and tablename like 'node\_%' escape '\'
) contract_state;

insert into symphony_staging.contract_versions (
  contract_name,
  contract_version,
  migration_name
)
values (
  'node-identity-routing-foundation',
  3,
  '20260724010000_aro_169_node_enrollment'
)
on conflict (contract_name) do update
set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name;

commit;
