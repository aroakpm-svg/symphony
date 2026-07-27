begin;

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('aroak:symphony_staging:migrations', 0)
);

do $$
declare
  managed_role name;
  managed_state record;
  expected_membership_count integer :=
    case when current_setting('is_superuser') = 'on' then 1 else 2 end;
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

  foreach managed_role in array array[
    'symphony_staging_runtime'::name,
    'symphony_staging_provisioner'::name
  ]
  loop
    select *
    into strict managed_state
    from pg_roles
    where rolname = managed_role;

    if managed_state.rolcanlogin
       or managed_state.rolsuper
       or managed_state.rolcreatedb
       or managed_state.rolcreaterole
       or managed_state.rolinherit
       or managed_state.rolreplication
       or managed_state.rolbypassrls
       or managed_state.rolconfig is not null then
      raise exception using
        errcode = '55000',
        message = format('ARO-169 unsafe ARO-168 role state for %s', managed_role);
    end if;

    if (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      where granted_role.rolname = managed_role
    ) <> expected_membership_count
    or (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      join pg_roles member_role on member_role.oid = membership.member
      join pg_roles grantor_role on grantor_role.oid = membership.grantor
      where granted_role.rolname = managed_role
        and member_role.rolname = 'postgres'
        and (
          (
            grantor_role.rolname = 'postgres'
            and not membership.admin_option
            and membership.inherit_option
            and membership.set_option
          )
          or (
            current_setting('is_superuser') <> 'on'
            and grantor_role.rolname = 'supabase_admin'
            and membership.admin_option
            and not membership.inherit_option
            and not membership.set_option
          )
        )
    ) <> expected_membership_count
    or exists (
      select 1
      from pg_auth_members membership
      where membership.member = managed_state.oid
         or membership.grantor = managed_state.oid
    ) then
      raise exception using
        errcode = '55000',
        message = format(
          'ARO-169 unsafe ARO-168 membership graph for %s',
          managed_role
        );
    end if;

    if not has_schema_privilege(managed_role, 'symphony_staging', 'USAGE')
       or has_schema_privilege(managed_role, 'symphony_staging', 'CREATE')
       or has_schema_privilege(managed_role, 'symphony_production', 'USAGE')
       or has_schema_privilege(managed_role, 'symphony_production', 'CREATE') then
      raise exception using
        errcode = '55000',
        message = format(
          'ARO-169 unsafe ARO-168 schema privileges for %s',
          managed_role
        );
    end if;
  end loop;

  if exists (
    select 1
    from (values ('anon'), ('authenticated'), ('service_role')) actor(role_name)
    where has_schema_privilege(actor.role_name, 'symphony_staging', 'USAGE')
       or has_schema_privilege(actor.role_name, 'symphony_staging', 'CREATE')
       or has_schema_privilege(actor.role_name, 'symphony_production', 'USAGE')
       or has_schema_privilege(actor.role_name, 'symphony_production', 'CREATE')
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 public role environment access';
  end if;

  if exists (
    select 1
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events',
        'foundation_audit_events_audit_id_seq'
      )
      and (
        pg_get_userbyid(relation.relowner) <> 'postgres'
        or (
          relation.relkind <> 'S'
          and (
            not relation.relrowsecurity
            or relation.relforcerowsecurity
          )
        )
      )
  )
  or exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'symphony_staging'
      and procedure.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and pg_get_userbyid(procedure.proowner) <> 'postgres'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 ownership or row-security state';
  end if;

  if exists (
    with expected(object_name, grantee_name, privilege_type) as (
      values
        ('contract_versions', 'symphony_staging_runtime', 'SELECT'),
        ('routing_assignments', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_runtime', 'USAGE'),
        ('contract_versions', 'symphony_staging_provisioner', 'SELECT'),
        ('contract_versions', 'symphony_staging_provisioner', 'INSERT'),
        ('contract_versions', 'symphony_staging_provisioner', 'UPDATE'),
        ('nodes', 'symphony_staging_provisioner', 'SELECT'),
        ('nodes', 'symphony_staging_provisioner', 'INSERT'),
        ('nodes', 'symphony_staging_provisioner', 'UPDATE'),
        ('node_bindings', 'symphony_staging_provisioner', 'SELECT'),
        ('node_bindings', 'symphony_staging_provisioner', 'INSERT'),
        ('node_bindings', 'symphony_staging_provisioner', 'UPDATE'),
        ('routing_assignments', 'symphony_staging_provisioner', 'SELECT'),
        ('routing_assignments', 'symphony_staging_provisioner', 'INSERT'),
        ('routing_assignments', 'symphony_staging_provisioner', 'UPDATE'),
        ('foundation_audit_events', 'symphony_staging_provisioner', 'INSERT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_provisioner', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_provisioner', 'USAGE')
    ),
    actual as (
      select
        relation.relname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      cross join lateral aclexplode(relation.relacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where namespace.nspname = 'symphony_staging'
        and relation.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events',
          'foundation_audit_events_audit_id_seq'
        )
        and grantee.rolname in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 direct object ACL state';
  end if;

  if exists (
    with expected(table_name, column_name, grantee_name, privilege_type) as (
      values
        ('nodes', 'node_id', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'display_alias', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'status', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'credential_version', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'created_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'updated_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'rotated_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'revoked_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'retired_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'binding_id', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'node_id', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'environment', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'status', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'credential_version', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'created_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'activated_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'rotated_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'revoked_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'retired_at', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events', 'event_type', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'node_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'binding_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'issue_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'routing_revision', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'credential_version', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'result', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'reason_code', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'details', 'symphony_staging_runtime', 'INSERT')
    ),
    actual as (
      select
        relation.relname::text,
        attribute.attname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_attribute attribute
      join pg_class relation on relation.oid = attribute.attrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      cross join lateral aclexplode(attribute.attacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where namespace.nspname = 'symphony_staging'
        and relation.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events'
        )
        and attribute.attnum > 0
        and not attribute.attisdropped
        and grantee.rolname in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 direct column ACL state';
  end if;

  if exists (
    select 1
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(coalesce(
      relation.relacl,
      acldefault(
        case when relation.relkind = 'S' then 'S'::"char" else 'r'::"char" end,
        relation.relowner
      )
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events',
        'foundation_audit_events_audit_id_seq'
      )
      and (
        acl.is_grantable and acl.grantee <> relation.relowner
        or coalesce(grantee.rolname, 'PUBLIC') not in (
          'postgres',
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
      )
  )
  or exists (
    select 1
    from pg_attribute attribute
    join pg_class relation on relation.oid = attribute.attrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(attribute.attacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events'
      )
      and attribute.attnum > 0
      and not attribute.attisdropped
      and (
        acl.is_grantable
        or coalesce(grantee.rolname, 'PUBLIC') not in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
      )
  )
  or exists (
    select 1
    from pg_default_acl default_acl
    left join pg_namespace namespace
      on namespace.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where (
        default_acl.defaclnamespace = 0
        or namespace.nspname in ('symphony_staging', 'symphony_production')
      )
      and coalesce(grantee.rolname, 'PUBLIC') in (
        'PUBLIC',
        'anon',
        'authenticated',
        'service_role',
        'symphony_staging_runtime',
        'symphony_staging_provisioner'
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 ACL or default-ACL state';
  end if;

  if exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    cross join lateral aclexplode(coalesce(
      procedure.proacl,
      acldefault('f', procedure.proowner)
    )) acl
    where namespace.nspname = 'symphony_staging'
      and procedure.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and (
        acl.grantee <> procedure.proowner
        or acl.is_grantable and acl.grantee <> procedure.proowner
      )
  )
  or exists (
    select 1
    from pg_namespace namespace
    cross join lateral aclexplode(coalesce(
      namespace.nspacl,
      acldefault('n', namespace.nspowner)
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where namespace.nspname in ('symphony_staging', 'symphony_production')
      and (
        acl.is_grantable and acl.grantee <> namespace.nspowner
        or coalesce(grantee.rolname, 'PUBLIC') in (
          'PUBLIC',
          'anon',
          'authenticated',
          'service_role'
        )
        or (
          namespace.nspname = 'symphony_production'
          and coalesce(grantee.rolname, 'PUBLIC') in (
            'symphony_staging_runtime',
            'symphony_staging_provisioner'
          )
        )
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 function or schema ACL state';
  end if;

  if exists (
    select 1
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'symphony_production'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 requires an empty production schema';
  end if;

  if exists (
    with expected(tablename, policyname, permissive, roles, cmd, qual, with_check) as (
      values
        ('contract_versions', 'runtime_read_contract_versions',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT',
         '(contract_name !~~ ''aro-163-created-role:%''::text)', null),
        ('nodes', 'runtime_read_nodes',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('node_bindings', 'runtime_read_node_bindings',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('routing_assignments', 'runtime_read_routing_assignments',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('foundation_audit_events', 'runtime_insert_audit_events',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'INSERT', null, 'true'),
        ('contract_versions', 'provisioner_manage_contract_versions',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL',
         '(contract_name !~~ ''aro-163-created-role:%''::text)',
         '(contract_name !~~ ''aro-163-created-role:%''::text)'),
        ('nodes', 'provisioner_manage_nodes',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('node_bindings', 'provisioner_manage_node_bindings',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('routing_assignments', 'provisioner_manage_routing_assignments',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('foundation_audit_events', 'provisioner_insert_audit_events',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'INSERT', null, 'true')
    ),
    actual as (
      select tablename, policyname, permissive, roles, cmd, qual, with_check
      from pg_policies
      where schemaname = 'symphony_staging'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 RLS policy state';
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

create table symphony_staging.node_principal_history (
  node_id uuid not null
    references symphony_staging.nodes(node_id) on delete restrict,
  credential_version integer not null check (credential_version > 0),
  login_role name not null unique,
  status text not null check (status in ('active', 'retired', 'revoked')),
  created_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  primary key (node_id, credential_version)
);

create table symphony_staging.node_lifecycle_operations (
  operation_id uuid primary key,
  operation_type text not null
    check (operation_type in (
      'provision', 'rotate', 'revoke', 'reenroll', 'retire_instance'
    )),
  request_fingerprint text not null,
  node_id uuid references symphony_staging.nodes(node_id) on delete restrict,
  binding_id uuid references symphony_staging.node_bindings(binding_id) on delete restrict,
  node_instance_id uuid,
  login_role name,
  credential_version integer,
  issue_id text,
  result_code text not null check (result_code = 'completed'),
  completed_at timestamptz not null default clock_timestamp()
);

alter table symphony_staging.node_login_principals enable row level security;
alter table symphony_staging.node_principal_history enable row level security;
alter table symphony_staging.node_lifecycle_operations enable row level security;

revoke all on table symphony_staging.node_login_principals
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
revoke all on table
  symphony_staging.node_principal_history,
  symphony_staging.node_lifecycle_operations
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop policy if exists provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
drop policy if exists provisioner_manage_nodes
  on symphony_staging.nodes;
drop policy if exists provisioner_manage_node_bindings
  on symphony_staging.node_bindings;
drop policy if exists provisioner_manage_routing_assignments
  on symphony_staging.routing_assignments;
drop policy if exists provisioner_insert_audit_events
  on symphony_staging.foundation_audit_events;

revoke all on table
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments,
  symphony_staging.foundation_audit_events
  from symphony_staging_provisioner;
revoke all on sequence
  symphony_staging.foundation_audit_events_audit_id_seq
  from symphony_staging_provisioner;

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
  requested_operation_id uuid,
  requested_display_alias text,
  requested_issue_id text,
  requested_routing_policy text
)
returns table (
  node_id uuid,
  binding_id uuid,
  login_role name,
  node_credential text,
  contract_version integer,
  credential_returned boolean
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
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 provisioning requires the staging provisioner';
  end if;

  if requested_operation_id is null
     or requested_display_alias is null
     or btrim(requested_display_alias) = ''
     or length(requested_display_alias) > 120
     or requested_issue_id is null
     or btrim(requested_issue_id) = ''
     or requested_routing_policy not in ('preferred-with-fallback', 'exclusive') then
    raise exception using
      errcode = '22023',
      message = 'operationId, display alias, issueId, and targeted routing policy are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, result_code
  )
  values (
    requested_operation_id,
    'provision',
    encode(extensions.digest(
      jsonb_build_array(
        btrim(requested_display_alias),
        btrim(requested_issue_id),
        requested_routing_policy
      )::text,
      'sha256'
    ), 'hex'),
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select
      operations.node_id,
      operations.binding_id,
      operations.login_role,
      null::text,
      3,
      false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'provision'
      and operations.request_fingerprint = encode(extensions.digest(
        jsonb_build_array(
          btrim(requested_display_alias),
          btrim(requested_issue_id),
          requested_routing_policy
        )::text,
        'sha256'
      ), 'hex')
      and operations.result_code = 'completed';

    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different or incomplete request';
    end if;
    return;
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

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (generated_node_id, 1, generated_login_role, 'active');

  insert into symphony_staging.routing_assignments (
    issue_id, routing_policy, target_node_id, routing_revision, contract_version
  )
  values (
    btrim(requested_issue_id),
    requested_routing_policy,
    generated_node_id,
    1,
    3
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
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id,
      'issue_id', btrim(requested_issue_id)
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set
    node_id = generated_node_id,
    binding_id = generated_binding_id,
    login_role = generated_login_role,
    credential_version = 1,
    issue_id = btrim(requested_issue_id),
    completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select
    generated_node_id,
    generated_binding_id,
    generated_login_role,
    generated_credential,
    3,
    true;
end
$$;

create or replace function symphony_staging.rotate_node_credential(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (
  node_id uuid,
  login_role name,
  node_credential text,
  credential_version integer,
  contract_version integer,
  credential_returned boolean
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
  request_hash text;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 rotation requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  request_hash := encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id,
    result_code
  )
  values (
    requested_operation_id, 'rotate', request_hash, requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.login_role, null::text,
           operations.credential_version, 3, false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'rotate'
      and operations.request_fingerprint = request_hash
      and operations.result_code = 'completed';
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
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

  update symphony_staging.node_principal_history history
  set status = 'retired', retired_at = clock_timestamp()
  where history.node_id = requested_node_id
    and history.login_role = principal_role
    and history.status = 'active';

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (
    requested_node_id, next_credential_version, replacement_role, 'active'
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
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set
    binding_id = generated_binding_id,
    login_role = replacement_role,
    credential_version = next_credential_version,
    completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select
    requested_node_id,
    replacement_role,
    generated_credential,
    next_credential_version,
    3,
    true;
end
$$;

create or replace function symphony_staging.retire_node_instance(
  requested_operation_id uuid,
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
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 instance retirement requires the staging provisioner';
  end if;

  if requested_operation_id is null
     or requested_node_id is null
     or requested_node_instance_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId, nodeId, and nodeInstanceId are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id,
    node_instance_id, result_code
  )
  values (
    requested_operation_id,
    'retire_instance',
    encode(extensions.digest(
      requested_node_id::text || E'\n' || requested_node_instance_id::text,
      'sha256'
    ), 'hex'),
    requested_node_id,
    requested_node_instance_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.node_instance_id, 3
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'retire_instance'
      and operations.request_fingerprint = encode(extensions.digest(
        requested_node_id::text || E'\n' || requested_node_instance_id::text,
        'sha256'
      ), 'hex');
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
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
      'operation_id', requested_operation_id,
      'environment', 'staging'
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;

  return query select requested_node_id, requested_node_instance_id, 3;
end
$$;

create or replace function symphony_staging.revoke_node(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (node_id uuid, contract_version integer)
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
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 revocation requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id, result_code
  )
  values (
    requested_operation_id,
    'revoke',
    encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex'),
    requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, 3
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'revoke'
      and operations.request_fingerprint =
        encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
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

  delete from symphony_staging.active_node_instances instances
  where instances.node_id = requested_node_id;

  update symphony_staging.node_principal_history history
  set status = 'revoked', retired_at = clock_timestamp()
  where history.node_id = requested_node_id
    and history.login_role = principal_role
    and history.status = 'active';

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
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;

  return query select requested_node_id, 3;
end
$$;

create or replace function symphony_staging.reenroll_node(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (
  node_id uuid,
  login_role name,
  node_credential text,
  credential_version integer,
  contract_version integer,
  credential_returned boolean
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  prior_role name;
  replacement_role name;
  generated_binding_id uuid := gen_random_uuid();
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
  next_credential_version integer;
  request_hash text;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 re-enrollment requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  request_hash := encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id, result_code
  )
  values (
    requested_operation_id, 'reenroll', request_hash, requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.login_role, null::text,
           operations.credential_version, 3, false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'reenroll'
      and operations.request_fingerprint = request_hash;
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
  end if;

  select principals.login_role, nodes.credential_version + 1
  into prior_role, next_credential_version
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes using (node_id)
  where principals.node_id = requested_node_id
    and principals.revoked_at is not null
    and nodes.status = 'disabled'
  for update of nodes, principals;

  if prior_role is null then
    raise exception using
      errcode = '02000',
      message = 'revoked node eligible for re-enrollment not found';
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

  update symphony_staging.nodes nodes
  set status = 'active',
      credential_version = next_credential_version,
      revoked_at = null,
      rotated_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id;

  update symphony_staging.node_login_principals principals
  set login_role = replacement_role, revoked_at = null
  where principals.node_id = requested_node_id;

  insert into symphony_staging.node_bindings (
    binding_id, node_id, environment, status, credential_version,
    credential_verifier, activated_at
  )
  values (
    generated_binding_id, requested_node_id, 'staging', 'active',
    next_credential_version, generated_verifier, clock_timestamp()
  );

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (
    requested_node_id, next_credential_version, replacement_role, 'active'
  );

  insert into symphony_staging.foundation_audit_events (
    event_type, node_id, binding_id, credential_version,
    result, reason_code, details
  )
  values (
    'node_reenrolled', requested_node_id, generated_binding_id,
    next_credential_version, 'accepted', 'revoked_node_reenrolled',
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set binding_id = generated_binding_id,
      login_role = replacement_role,
      credential_version = next_credential_version,
      completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select requested_node_id, replacement_role, generated_credential,
         next_credential_version, 3, true;
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
  symphony_staging.provision_node(uuid, text, text, text),
  symphony_staging.rotate_node_credential(uuid, uuid),
  symphony_staging.revoke_node(uuid, uuid),
  symphony_staging.reenroll_node(uuid, uuid),
  symphony_staging.retire_node_instance(uuid, uuid, uuid),
  symphony_staging.authenticate_node(uuid, uuid)
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

grant execute on function
  symphony_staging.provision_node(uuid, text, text, text)
  to symphony_staging_provisioner;
grant execute on function
  symphony_staging.rotate_node_credential(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.revoke_node(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.reenroll_node(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function
  symphony_staging.retire_node_instance(uuid, uuid, uuid)
  to symphony_staging_provisioner;

insert into symphony_staging.node_enrollment_contract_manifest (
  expected_fingerprint
)
select md5(string_agg(signature, E'\n' order by signature))
from (
  with recursive descendant_roles(role_oid) as (
    select oid
    from pg_roles
    where rolname in (
      'symphony_staging_runtime',
      'symphony_staging_provisioner'
    )
    union
    select membership.member
    from descendant_roles
    join pg_auth_members membership
      on membership.roleid = descendant_roles.role_oid
  ),
  ancestor_roles(role_oid) as (
    select oid
    from pg_roles
    where rolname in (
      'symphony_staging_runtime',
      'symphony_staging_provisioner'
    )
    union
    select membership.roleid
    from ancestor_roles
    join pg_auth_members membership
      on membership.member = ancestor_roles.role_oid
  )
  select
    'role:' || role_state.rolname || ':' ||
    role_state.rolsuper::text || ':' ||
    role_state.rolinherit::text || ':' ||
    role_state.rolcreaterole::text || ':' ||
    role_state.rolcreatedb::text || ':' ||
    role_state.rolcanlogin::text || ':' ||
    role_state.rolreplication::text || ':' ||
    role_state.rolconnlimit::text || ':' ||
    coalesce(role_state.rolvaliduntil::text, '') || ':' ||
    role_state.rolbypassrls::text || ':' ||
    coalesce(role_state.rolconfig::text, '') as signature
  from pg_roles role_state
  where role_state.rolname in (
    'symphony_staging_runtime',
    'symphony_staging_provisioner'
  )
  union all
  select
    'schema:' || namespace.nspname || ':' ||
    pg_get_userbyid(namespace.nspowner) || ':' ||
    coalesce(namespace.nspacl::text, '')
  from pg_namespace namespace
  where namespace.nspname in ('symphony_staging', 'symphony_production')
  union all
  select
    'default-acl:' || pg_get_userbyid(default_acl.defaclrole) || ':' ||
    coalesce(namespace.nspname, '') || ':' ||
    default_acl.defaclobjtype::text || ':' ||
    default_acl.defaclacl::text
  from pg_default_acl default_acl
  left join pg_namespace namespace
    on namespace.oid = default_acl.defaclnamespace
  where pg_get_userbyid(default_acl.defaclrole) = 'postgres'
    and (
      default_acl.defaclnamespace = 0
      or namespace.nspname in ('symphony_staging', 'symphony_production')
    )
  union all
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
      'reenroll_node',
      'retire_node_instance',
      'authenticate_node'
    )
  union all
  select
    'membership:' || granted_role.rolname || ':' || member_role.rolname || ':' ||
    grantor_role.rolname || ':' || membership.admin_option::text || ':' ||
    membership.inherit_option::text || ':' || membership.set_option::text
  from pg_auth_members membership
  join pg_roles granted_role on granted_role.oid = membership.roleid
  join pg_roles member_role on member_role.oid = membership.member
  join pg_roles grantor_role on grantor_role.oid = membership.grantor
  where membership.roleid in (select role_oid from descendant_roles)
     or membership.member in (select role_oid from ancestor_roles)
  union all
  select
    'table:' || relation.relname || ':' ||
    pg_get_userbyid(relation.relowner) || ':' ||
    relation.relrowsecurity::text || ':' ||
    relation.relforcerowsecurity::text || ':' ||
    coalesce(relation.relacl::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events',
      'foundation_audit_events_audit_id_seq'
    )
  union all
  select
    'sequence:' || relation.relname || ':' ||
    sequence_state.seqtypid::regtype::text || ':' ||
    sequence_state.seqstart::text || ':' ||
    sequence_state.seqincrement::text || ':' ||
    sequence_state.seqmin::text || ':' ||
    sequence_state.seqmax::text || ':' ||
    sequence_state.seqcache::text || ':' ||
    sequence_state.seqcycle::text
  from pg_sequence sequence_state
  join pg_class relation on relation.oid = sequence_state.seqrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname = 'foundation_audit_events_audit_id_seq'
  union all
  select
    'index:' || relation.relname || ':' || index_relation.relname || ':' ||
    pg_get_indexdef(index_relation.oid)
  from pg_index index_state
  join pg_class relation on relation.oid = index_state.indrelid
  join pg_class index_relation on index_relation.oid = index_state.indexrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'column:' || relation.relname || ':' || attribute.attname || ':' ||
    format_type(attribute.atttypid, attribute.atttypmod) || ':' ||
    attribute.attnotnull::text || ':' ||
    coalesce(pg_get_expr(default_value.adbin, default_value.adrelid), '') || ':' ||
    coalesce(attribute.attacl::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_attribute attribute on attribute.attrelid = relation.oid
  left join pg_attrdef default_value
    on default_value.adrelid = relation.oid
   and default_value.adnum = attribute.attnum
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
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
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'policy:' || schemaname || ':' || tablename || ':' || policyname || ':' ||
    permissive || ':' || roles::text || ':' || cmd || ':' ||
    coalesce(qual, '') || ':' || coalesce(with_check, '')
  from pg_policies
  where schemaname = 'symphony_staging'
    and tablename in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'trigger:' || relation.relname || ':' || trigger_row.tgname || ':' ||
    trigger_row.tgenabled::text || ':' ||
    pg_get_triggerdef(trigger_row.oid, true) || ':' ||
    trigger_function.oid::regprocedure::text || ':' ||
    pg_get_userbyid(trigger_function.proowner) || ':' ||
    coalesce(trigger_function.proacl::text, '') || ':' ||
    pg_get_functiondef(trigger_function.oid)
  from pg_trigger trigger_row
  join pg_class relation on relation.oid = trigger_row.tgrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_proc trigger_function on trigger_function.oid = trigger_row.tgfoid
  where namespace.nspname = 'symphony_staging'
    and not trigger_row.tgisinternal
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
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
