begin;

do $$
declare
  locked_contract_version integer;
  locked_migration_name text;
  recorded_fingerprint text;
  current_fingerprint text;
begin
  select contract_version, migration_name
  into locked_contract_version, locked_migration_name
  from symphony_staging.contract_versions
  where contract_name = 'node-identity-routing-foundation'
  for update;

  if locked_contract_version is distinct from 3
     or locked_migration_name is distinct from
       '20260724010000_aro_169_node_enrollment' then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 rollback requires the exact contract v3 marker';
  end if;

  lock table
    symphony_staging.node_login_principals,
    symphony_staging.node_instance_history,
    symphony_staging.active_node_instances,
    symphony_staging.node_enrollment_contract_manifest
    in access exclusive mode;

  if exists (
    select 1
    from symphony_staging.node_login_principals
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 rollback refused while provisioned node principals exist';
  end if;

  select expected_fingerprint
  into recorded_fingerprint
  from symphony_staging.node_enrollment_contract_manifest
  where singleton;

  select md5(string_agg(signature, E'\n' order by signature))
  into current_fingerprint
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
      'constraint:' || relation.relname || ':' ||
      constraint_row.conname || ':' ||
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

  if recorded_fingerprint is null
     or current_fingerprint is distinct from recorded_fingerprint then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 rollback refused because contract objects or ACLs drifted';
  end if;
end
$$;

drop function if exists symphony_staging.authenticate_node(uuid, uuid);
drop function if exists symphony_staging.revoke_node(uuid);
drop function if exists symphony_staging.rotate_node_credential(uuid);
drop function if exists symphony_staging.provision_node(text);
drop table if exists symphony_staging.active_node_instances;
drop table if exists symphony_staging.node_instance_history;
drop table if exists symphony_staging.node_login_principals;
drop table if exists symphony_staging.node_enrollment_contract_manifest;

do $$
begin
  update symphony_staging.contract_versions
  set
    contract_version = 2,
    migration_name = '20260724000000_aro_168_staging_reconciliation'
  where contract_name = 'node-identity-routing-foundation'
    and contract_version = 3
    and migration_name = '20260724010000_aro_169_node_enrollment';

  if not found then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 rollback contract downgrade did not update exactly one row';
  end if;
end
$$;

commit;
