begin;

do $aro_168_gate$
declare
  checked_role name;
  role_state record;
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
            grantor_role.rolname = 'supabase_admin'
            and membership.admin_option
            and not membership.inherit_option
            and not membership.set_option
          )
        )
    ) <> 2
    or (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      where granted_role.rolname = checked_role
    ) <> 2 then
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
    with expected(tablename, policyname, roles, cmd, qual, with_check) as (
      values
        ('contract_versions', 'runtime_read_contract_versions',
         array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('nodes', 'runtime_read_nodes',
         array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('node_bindings', 'runtime_read_node_bindings',
         array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('routing_assignments', 'runtime_read_routing_assignments',
         array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('foundation_audit_events', 'runtime_insert_audit_events',
         array['symphony_staging_runtime']::name[], 'INSERT', null, 'true'),
        ('contract_versions', 'provisioner_manage_contract_versions',
         array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('nodes', 'provisioner_manage_nodes',
         array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('node_bindings', 'provisioner_manage_node_bindings',
         array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('routing_assignments', 'provisioner_manage_routing_assignments',
         array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('foundation_audit_events', 'provisioner_insert_audit_events',
         array['symphony_staging_provisioner']::name[], 'INSERT', null, 'true')
    ),
    actual as (
      select tablename, policyname, roles, cmd, qual, with_check
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
    from pg_class object
    join pg_namespace schema on schema.oid = object.relnamespace
    where schema.nspname = 'symphony_production'
      and object.relkind in ('r', 'p')
  )
  or exists (
    select 1
    from pg_proc function
    join pg_namespace schema on schema.oid = function.pronamespace
    where schema.nspname = 'symphony_production'
  ) then
    raise exception 'ARO-168 production must remain empty';
  end if;
end
$aro_168_gate$;

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
          '(contract_name !~~ ''aro-163-created-role:%''::text)' then
    raise exception 'ARO-168 postcondition failed';
  end if;
end
$aro_168_verify$;

commit;
