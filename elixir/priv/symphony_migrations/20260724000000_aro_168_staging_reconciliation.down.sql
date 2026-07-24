begin;

lock table
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments,
  symphony_staging.foundation_audit_events
  in access exclusive mode;

do $aro_168_rollback_gate$
begin
  if (select count(*) from symphony_staging.nodes) <> 0
     or (select count(*) from symphony_staging.node_bindings) <> 0
     or (select count(*) from symphony_staging.routing_assignments) <> 0
     or (select count(*) from symphony_staging.foundation_audit_events) <> 0
     or (select rolconfig from pg_roles where rolname = 'symphony_staging_runtime') is not null
     or (select rolconfig from pg_roles where rolname = 'symphony_staging_provisioner') is not null
     or exists (
       select 1
       from pg_db_role_setting role_setting
       join pg_roles role on role.oid = role_setting.setrole
       where role.rolname in (
         'symphony_staging_runtime',
         'symphony_staging_provisioner'
       )
         and role_setting.setdatabase = (
           select oid from pg_database where datname = current_database()
         )
     )
     or exists (
       select 1
       from pg_auth_members membership
       join pg_roles managed_role
         on managed_role.oid = membership.member
         or managed_role.oid = membership.grantor
       where managed_role.rolname in (
         'symphony_staging_runtime',
         'symphony_staging_provisioner'
       )
     )
     or exists (
       select 1
       from (values
         ('symphony_staging_runtime'::name),
         ('symphony_staging_provisioner'::name)
       ) managed(role_name)
       where (
         select count(*)
         from pg_auth_members membership
         join pg_roles granted_role on granted_role.oid = membership.roleid
         where granted_role.rolname = managed.role_name
       ) <> case when current_setting('is_superuser') = 'on' then 1 else 2 end
       or (
         select count(*)
         from pg_auth_members membership
         join pg_roles granted_role on granted_role.oid = membership.roleid
         join pg_roles member_role on member_role.oid = membership.member
         join pg_roles grantor_role on grantor_role.oid = membership.grantor
         where granted_role.rolname = managed.role_name
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
       ) <> case when current_setting('is_superuser') = 'on' then 1 else 2 end
     )
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
    raise exception 'ARO-168 rollback refused unexpected v2 state';
  end if;
end
$aro_168_rollback_gate$;

do $aro_168_rollback_acl_gate$
begin
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
    raise exception 'ARO-168 rollback refused direct object ACL drift';
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
    raise exception 'ARO-168 rollback refused direct column ACL drift';
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
    left join pg_namespace schema on schema.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where (
        default_acl.defaclnamespace = 0
        or schema.nspname in ('symphony_staging', 'symphony_production')
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
    raise exception 'ARO-168 rollback refused ACL or default-ACL drift';
  end if;

  if exists (
    select 1
    from pg_proc function
    join pg_namespace schema on schema.oid = function.pronamespace
    cross join lateral aclexplode(coalesce(
      function.proacl,
      acldefault('f', function.proowner)
    )) acl
    where schema.nspname = 'symphony_staging'
      and function.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and acl.grantee <> function.proowner
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
    raise exception 'ARO-168 rollback refused function or schema ACL drift';
  end if;
end
$aro_168_rollback_acl_gate$;

drop policy runtime_read_contract_versions
  on symphony_staging.contract_versions;
create policy runtime_read_contract_versions
  on symphony_staging.contract_versions
  for select
  to symphony_staging_runtime
  using (true);

drop policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
create policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);

alter role symphony_staging_runtime
  set search_path = pg_catalog, symphony_staging;
alter role symphony_staging_provisioner
  set search_path = pg_catalog, symphony_staging;

update symphony_staging.contract_versions
set
  contract_version = 1,
  migration_name = '20260723000000_aro_163_staging_foundation'
where contract_name = 'node-identity-routing-foundation';

do $aro_168_rollback_verify$
begin
  if (select rolconfig from pg_roles where rolname = 'symphony_staging_runtime')
       is distinct from array['search_path=pg_catalog, symphony_staging']::text[]
     or (select rolconfig from pg_roles where rolname = 'symphony_staging_provisioner')
       is distinct from array['search_path=pg_catalog, symphony_staging']::text[]
     or exists (
       select 1
       from pg_db_role_setting role_setting
       join pg_roles role on role.oid = role_setting.setrole
       where role.rolname in (
         'symphony_staging_runtime',
         'symphony_staging_provisioner'
       )
         and role_setting.setdatabase = (
           select oid from pg_database where datname = current_database()
         )
     )
     or exists (
       select 1
       from pg_auth_members membership
       join pg_roles managed_role
         on managed_role.oid = membership.member
         or managed_role.oid = membership.grantor
       where managed_role.rolname in (
         'symphony_staging_runtime',
         'symphony_staging_provisioner'
       )
     )
     or exists (
       select 1
       from (values
         ('symphony_staging_runtime'::name),
         ('symphony_staging_provisioner'::name)
       ) managed(role_name)
       where (
         select count(*)
         from pg_auth_members membership
         join pg_roles granted_role on granted_role.oid = membership.roleid
         where granted_role.rolname = managed.role_name
       ) <> case when current_setting('is_superuser') = 'on' then 1 else 2 end
       or (
         select count(*)
         from pg_auth_members membership
         join pg_roles granted_role on granted_role.oid = membership.roleid
         join pg_roles member_role on member_role.oid = membership.member
         join pg_roles grantor_role on grantor_role.oid = membership.grantor
         where granted_role.rolname = managed.role_name
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
       ) <> case when current_setting('is_superuser') = 'on' then 1 else 2 end
     )
     or not exists (
       select 1
       from symphony_staging.contract_versions
       where contract_name = 'node-identity-routing-foundation'
         and contract_version = 1
         and migration_name = '20260723000000_aro_163_staging_foundation'
     )
     or (select qual from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'runtime_read_contract_versions')
          is distinct from 'true'
     or (select qual from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'provisioner_manage_contract_versions')
          is distinct from 'true'
     or (select with_check from pg_policies
         where schemaname = 'symphony_staging'
           and policyname = 'provisioner_manage_contract_versions')
          is distinct from 'true' then
    raise exception 'ARO-168 rollback postcondition failed';
  end if;
end
$aro_168_rollback_verify$;

commit;
