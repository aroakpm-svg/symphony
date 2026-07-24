begin;

do $aro_168_gate$
declare
  checked_role name;
  role_state record;
  expected_membership_count integer :=
    case when current_setting('is_superuser') = 'on' then 1 else 2 end;
begin
  if current_database() is null then
    raise exception 'ARO-168 cannot identify the target database';
  end if;

  if to_regnamespace('symphony_staging') is null
     or to_regnamespace('symphony_production') is null then
    raise exception 'ARO-168 requires both environment schemas';
  end if;

  if (
    select count(*)
    from pg_class object
    join pg_namespace schema on schema.oid = object.relnamespace
    where schema.nspname = 'symphony_staging'
      and object.relkind in ('r', 'p')
  ) <> 5
  or exists (
    select 1
    from (values
      ('contract_versions'),
      ('nodes'),
      ('node_bindings'),
      ('routing_assignments'),
      ('foundation_audit_events')
    ) expected(table_name)
    where to_regclass('symphony_staging.' || expected.table_name) is null
  ) then
    raise exception 'ARO-168 unexpected staging table state';
  end if;

  if (
    select count(*)
    from pg_proc function
    join pg_namespace schema on schema.oid = function.pronamespace
    where schema.nspname = 'symphony_staging'
  ) <> 3
  or to_regprocedure('symphony_staging.enforce_node_transition()') is null
  or to_regprocedure('symphony_staging.enforce_node_binding_transition()') is null
  or to_regprocedure('symphony_staging.enforce_routing_revision()') is null then
    raise exception 'ARO-168 unexpected staging function state';
  end if;

  if exists (
    with expected(table_name, row_security, force_row_security) as (
      values
        ('contract_versions', true, false),
        ('nodes', true, false),
        ('node_bindings', true, false),
        ('routing_assignments', true, false),
        ('foundation_audit_events', true, false)
    ),
    actual as (
      select
        object.relname::text,
        object.relrowsecurity,
        object.relforcerowsecurity
      from pg_class object
      join pg_namespace schema on schema.oid = object.relnamespace
      where schema.nspname = 'symphony_staging'
        and object.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception 'ARO-168 unexpected row-security state';
  end if;

  if exists (
    with expected(trigger_name, table_name, function_name, enabled, internal, trigger_type) as (
      values
        (
          'enforce_node_transition',
          'nodes',
          'enforce_node_transition',
          'O'::"char",
          false,
          19::smallint
        ),
        (
          'enforce_node_binding_transition',
          'node_bindings',
          'enforce_node_binding_transition',
          'O'::"char",
          false,
          19::smallint
        ),
        (
          'enforce_routing_revision',
          'routing_assignments',
          'enforce_routing_revision',
          'O'::"char",
          false,
          19::smallint
        )
    ),
    actual as (
      select
        trigger.tgname::text,
        table_object.relname::text,
        function.proname::text,
        trigger.tgenabled,
        trigger.tgisinternal,
        trigger.tgtype
      from pg_trigger trigger
      join pg_class table_object on table_object.oid = trigger.tgrelid
      join pg_namespace table_schema on table_schema.oid = table_object.relnamespace
      join pg_proc function on function.oid = trigger.tgfoid
      join pg_namespace function_schema on function_schema.oid = function.pronamespace
      where table_schema.nspname = 'symphony_staging'
        and function_schema.nspname = 'symphony_staging'
        and not trigger.tgisinternal
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception 'ARO-168 unexpected trigger attachment state';
  end if;

  if (select count(*) from symphony_staging.nodes) <> 0
     or (select count(*) from symphony_staging.node_bindings) <> 0
     or (select count(*) from symphony_staging.routing_assignments) <> 0
     or (select count(*) from symphony_staging.foundation_audit_events) <> 0
     or (select count(*) from symphony_staging.contract_versions) <> 1
     or not exists (
       select 1
       from symphony_staging.contract_versions
       where contract_name = 'node-identity-routing-foundation'
         and contract_version = 1
         and migration_name = '20260723000000_aro_163_staging_foundation'
     )
     or exists (
       select 1 from symphony_staging.contract_versions
       where contract_name like 'aro-163-created-role:%'
     ) then
    raise exception 'ARO-168 unexpected foundation data state';
  end if;

  foreach checked_role in array array[
    'symphony_staging_runtime'::name,
    'symphony_staging_provisioner'::name
  ]
  loop
    select *
    into strict role_state
    from pg_roles
    where rolname = checked_role;

    if role_state.rolcanlogin
       or role_state.rolsuper
       or role_state.rolcreatedb
       or role_state.rolcreaterole
       or role_state.rolinherit
       or role_state.rolreplication
       or role_state.rolbypassrls
       or role_state.rolconfig is distinct from
         array['search_path=pg_catalog, symphony_staging']::text[] then
      raise exception 'ARO-168 unsafe role attributes for %', checked_role;
    end if;

    if (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      join pg_roles member_role on member_role.oid = membership.member
      join pg_roles grantor_role on grantor_role.oid = membership.grantor
      where granted_role.rolname = checked_role
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
            and
            grantor_role.rolname = 'supabase_admin'
            and membership.admin_option
            and not membership.inherit_option
            and not membership.set_option
          )
        )
    ) <> expected_membership_count
    or (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      where granted_role.rolname = checked_role
    ) <> expected_membership_count then
      raise exception 'ARO-168 unsafe managed membership state for %', checked_role;
    end if;

    if not has_schema_privilege(checked_role, 'symphony_staging', 'USAGE')
       or has_schema_privilege(checked_role, 'symphony_staging', 'CREATE')
       or has_schema_privilege(checked_role, 'symphony_production', 'USAGE')
       or has_schema_privilege(checked_role, 'symphony_production', 'CREATE') then
      raise exception 'ARO-168 unsafe schema privileges for %', checked_role;
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
    raise exception 'ARO-168 public role environment access is unsafe';
  end if;

  if exists (
    with expected(tablename, policyname, permissive, roles, cmd, qual, with_check) as (
      values
        ('contract_versions', 'runtime_read_contract_versions',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('nodes', 'runtime_read_nodes',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('node_bindings', 'runtime_read_node_bindings',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('routing_assignments', 'runtime_read_routing_assignments',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('foundation_audit_events', 'runtime_insert_audit_events',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'INSERT', null, 'true'),
        ('contract_versions', 'provisioner_manage_contract_versions',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
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
    raise exception 'ARO-168 unexpected legacy policy state';
  end if;

  if exists (
    select 1
    from (values
      ('contract_versions'),
      ('nodes'),
      ('node_bindings'),
      ('routing_assignments'),
      ('foundation_audit_events')
    ) expected(table_name)
    where (
      select owner.rolname
      from pg_class object
      join pg_namespace schema on schema.oid = object.relnamespace
      join pg_roles owner on owner.oid = object.relowner
      where schema.nspname = 'symphony_staging'
        and object.relname = expected.table_name
    ) <> 'postgres'
  )
  or exists (
    select 1
    from (values
      ('enforce_node_transition'),
      ('enforce_node_binding_transition'),
      ('enforce_routing_revision')
    ) expected(function_name)
    where (
      select owner.rolname
      from pg_proc function
      join pg_namespace schema on schema.oid = function.pronamespace
      join pg_roles owner on owner.oid = function.proowner
      where schema.nspname = 'symphony_staging'
        and function.proname = expected.function_name
        and function.pronargs = 0
    ) <> 'postgres'
  ) then
    raise exception 'ARO-168 unexpected foundation ownership state';
  end if;

  if not has_table_privilege(
       'symphony_staging_runtime',
       'symphony_staging.contract_versions',
       'SELECT'
     )
     or has_table_privilege(
       'symphony_staging_runtime',
       'symphony_staging.nodes',
       'SELECT'
     )
     or not has_column_privilege(
       'symphony_staging_runtime',
       'symphony_staging.nodes',
       'node_id',
       'SELECT'
     )
     or has_column_privilege(
       'symphony_staging_runtime',
       'symphony_staging.node_bindings',
       'credential_verifier',
       'SELECT'
     )
     or not has_table_privilege(
       'symphony_staging_runtime',
       'symphony_staging.routing_assignments',
       'SELECT'
     )
     or has_table_privilege(
       'symphony_staging_runtime',
       'symphony_staging.foundation_audit_events',
       'INSERT'
     )
     or not has_column_privilege(
       'symphony_staging_runtime',
       'symphony_staging.foundation_audit_events',
       'event_type',
       'INSERT'
     )
     or not has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'SELECT'
     )
     or not has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'INSERT'
     )
     or not has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'UPDATE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'DELETE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'TRUNCATE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'REFERENCES'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.nodes',
       'TRIGGER'
     )
     or not has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'INSERT'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'SELECT'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'UPDATE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'DELETE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'TRUNCATE'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'REFERENCES'
     )
     or has_table_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events',
       'TRIGGER'
     )
     or not has_sequence_privilege(
       'symphony_staging_runtime',
       'symphony_staging.foundation_audit_events_audit_id_seq',
       'USAGE'
     )
     or not has_sequence_privilege(
       'symphony_staging_runtime',
       'symphony_staging.foundation_audit_events_audit_id_seq',
       'SELECT'
     )
     or not has_sequence_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events_audit_id_seq',
       'USAGE'
     )
     or not has_sequence_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.foundation_audit_events_audit_id_seq',
       'SELECT'
     )
     or has_function_privilege(
       'symphony_staging_runtime',
       'symphony_staging.enforce_node_transition()',
       'EXECUTE'
     )
     or has_function_privilege(
       'symphony_staging_provisioner',
       'symphony_staging.enforce_node_transition()',
       'EXECUTE'
     ) then
    raise exception 'ARO-168 unexpected canonical object capability state';
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
        object.relname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_class object
      join pg_namespace schema on schema.oid = object.relnamespace
      cross join lateral aclexplode(object.relacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where schema.nspname = 'symphony_staging'
        and object.relname in (
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
    raise exception 'ARO-168 unexpected direct object ACL state';
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
        object.relname::text,
        column_attribute.attname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_attribute column_attribute
      join pg_class object on object.oid = column_attribute.attrelid
      join pg_namespace schema on schema.oid = object.relnamespace
      cross join lateral aclexplode(column_attribute.attacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where schema.nspname = 'symphony_staging'
        and object.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events'
        )
        and column_attribute.attnum > 0
        and not column_attribute.attisdropped
        and grantee.rolname in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception 'ARO-168 unexpected direct column ACL state';
  end if;

  if exists (
    select 1
    from pg_class object
    join pg_namespace schema on schema.oid = object.relnamespace
    cross join lateral aclexplode(coalesce(
      object.relacl,
      acldefault(case when object.relkind = 'S' then 'S'::"char" else 'r'::"char" end, object.relowner)
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where schema.nspname = 'symphony_staging'
      and object.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events',
        'foundation_audit_events_audit_id_seq'
      )
      and (
        acl.is_grantable and acl.grantee <> object.relowner
        or coalesce(grantee.rolname, 'PUBLIC') not in (
          'postgres',
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
      )
  )
  or exists (
    select 1
    from pg_attribute column_attribute
    join pg_class object on object.oid = column_attribute.attrelid
    join pg_namespace schema on schema.oid = object.relnamespace
    cross join lateral aclexplode(column_attribute.attacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where schema.nspname = 'symphony_staging'
      and object.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events'
      )
      and column_attribute.attnum > 0
      and not column_attribute.attisdropped
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
    join pg_namespace schema on schema.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where schema.nspname in ('symphony_staging', 'symphony_production')
      and coalesce(grantee.rolname, 'PUBLIC') in (
        'PUBLIC',
        'anon',
        'authenticated',
        'service_role',
        'symphony_staging_runtime',
        'symphony_staging_provisioner'
      )
  ) then
    raise exception 'ARO-168 unexpected ACL or default-ACL state';
  end if;

  if exists (
    select 1
    from pg_proc function
    join pg_namespace schema on schema.oid = function.pronamespace
    cross join lateral aclexplode(coalesce(
      function.proacl,
      acldefault('f', function.proowner)
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where schema.nspname = 'symphony_staging'
      and function.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and (
        acl.grantee <> function.proowner
        or acl.is_grantable and acl.grantee <> function.proowner
      )
  )
  or exists (
    select 1
    from pg_namespace schema
    cross join lateral aclexplode(coalesce(
      schema.nspacl,
      acldefault('n', schema.nspowner)
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where schema.nspname in ('symphony_staging', 'symphony_production')
      and (
        acl.is_grantable and acl.grantee <> schema.nspowner
        or coalesce(grantee.rolname, 'PUBLIC') in (
          'PUBLIC',
          'anon',
          'authenticated',
          'service_role'
        )
        or (
          schema.nspname = 'symphony_production'
          and coalesce(grantee.rolname, 'PUBLIC') in (
            'symphony_staging_runtime',
            'symphony_staging_provisioner'
          )
        )
      )
  ) then
    raise exception 'ARO-168 unexpected function or schema ACL state';
  end if;

  if exists (
    select 1
    from pg_class object
    join pg_namespace schema on schema.oid = object.relnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_proc function
    join pg_namespace schema on schema.oid = function.pronamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_type object
    join pg_namespace schema on schema.oid = object.typnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_operator object
    join pg_namespace schema on schema.oid = object.oprnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_collation object
    join pg_namespace schema on schema.oid = object.collnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_conversion object
    join pg_namespace schema on schema.oid = object.connamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_opclass object
    join pg_namespace schema on schema.oid = object.opcnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_opfamily object
    join pg_namespace schema on schema.oid = object.opfnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_ts_config object
    join pg_namespace schema on schema.oid = object.cfgnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_ts_dict object
    join pg_namespace schema on schema.oid = object.dictnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_ts_parser object
    join pg_namespace schema on schema.oid = object.prsnamespace
    where schema.nspname = 'symphony_production'
  )
  or exists (
    select 1
    from pg_ts_template object
    join pg_namespace schema on schema.oid = object.tmplnamespace
    where schema.nspname = 'symphony_production'
  ) then
    raise exception 'ARO-168 production must remain empty';
  end if;
end
$aro_168_gate$;

lock table
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments,
  symphony_staging.foundation_audit_events
  in access exclusive mode;

alter role symphony_staging_runtime reset search_path;
alter role symphony_staging_provisioner reset search_path;

drop policy runtime_read_contract_versions
  on symphony_staging.contract_versions;
create policy runtime_read_contract_versions
  on symphony_staging.contract_versions
  for select
  to symphony_staging_runtime
  using (contract_name not like 'aro-163-created-role:%');

drop policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
create policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions
  for all
  to symphony_staging_provisioner
  using (contract_name not like 'aro-163-created-role:%')
  with check (contract_name not like 'aro-163-created-role:%');

update symphony_staging.contract_versions
set
  contract_version = 2,
  migration_name = '20260724000000_aro_168_staging_reconciliation'
where contract_name = 'node-identity-routing-foundation';

do $aro_168_verify$
begin
  if (select rolconfig from pg_roles where rolname = 'symphony_staging_runtime') is not null
     or (select rolconfig from pg_roles where rolname = 'symphony_staging_provisioner') is not null
     or not exists (
       select 1
       from symphony_staging.contract_versions
       where contract_name = 'node-identity-routing-foundation'
         and contract_version = 2
         and migration_name = '20260724000000_aro_168_staging_reconciliation'
     )
     or (select qual from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'runtime_read_contract_versions')
          is distinct from
          '(contract_name !~~ ''aro-163-created-role:%''::text)'
     or (select qual from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'provisioner_manage_contract_versions')
          is distinct from
          '(contract_name !~~ ''aro-163-created-role:%''::text)'
     or (select with_check from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'provisioner_manage_contract_versions')
          is distinct from
          '(contract_name !~~ ''aro-163-created-role:%''::text)'
     or (select permissive from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'runtime_read_contract_versions')
          is distinct from 'PERMISSIVE'
     or (select permissive from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'provisioner_manage_contract_versions')
          is distinct from 'PERMISSIVE'
     or exists (
       select 1
       from pg_class object
       join pg_namespace schema on schema.oid = object.relnamespace
       where schema.nspname = 'symphony_staging'
         and object.relname in (
           'contract_versions',
           'nodes',
           'node_bindings',
           'routing_assignments',
           'foundation_audit_events'
         )
         and (not object.relrowsecurity or object.relforcerowsecurity)
     )
     or has_column_privilege(
       'symphony_staging_runtime',
       'symphony_staging.node_bindings',
       'credential_verifier',
       'SELECT'
     ) then
    raise exception 'ARO-168 postcondition failed';
  end if;
end
$aro_168_verify$;

commit;
