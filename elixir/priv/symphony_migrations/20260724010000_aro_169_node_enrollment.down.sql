begin;

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('aroak:symphony_staging:migrations', 0)
);

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
    symphony_staging.node_principal_history,
    symphony_staging.node_lifecycle_operations,
    symphony_staging.node_instance_history,
    symphony_staging.active_node_instances,
    symphony_staging.node_enrollment_contract_manifest
    in access exclusive mode;

  if exists (
    select 1
    from symphony_staging.node_principal_history
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
      'inventory-relation:' || namespace.nspname || ':' ||
      relation.relname || ':' || relation.relkind::text || ':' ||
      relation.relpersistence::text || ':' ||
      relation.relreplident::text || ':' ||
      relation.relrowsecurity::text || ':' ||
      relation.relforcerowsecurity::text || ':' ||
      relation.relhasrules::text || ':' ||
      relation.relhastriggers::text || ':' ||
      relation.relispopulated::text || ':' ||
      coalesce(relation.reloptions::text, '')
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('symphony_staging', 'symphony_production')
    union all
    select
      'inventory-function:' || procedure.oid::regprocedure::text
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-type:' || type_object.typname || ':' ||
      type_object.typtype::text || ':' || type_object.typcategory::text
    from pg_type type_object
    join pg_namespace namespace on namespace.oid = type_object.typnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select 'inventory-operator:' || operator_object.oid::regoperator::text
    from pg_operator operator_object
    join pg_namespace namespace on namespace.oid = operator_object.oprnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select 'inventory-collation:' || collation_object.collname
    from pg_collation collation_object
    join pg_namespace namespace on namespace.oid = collation_object.collnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-conversion:' || conversion_object.conname || ':' ||
      pg_get_userbyid(conversion_object.conowner) || ':' ||
      conversion_object.conforencoding::text || ':' ||
      conversion_object.contoencoding::text || ':' ||
      conversion_object.conproc::regprocedure::text || ':' ||
      conversion_object.condefault::text
    from pg_conversion conversion_object
    join pg_namespace namespace on namespace.oid = conversion_object.connamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-opclass:' || opclass_object.opcname || ':' ||
      pg_get_userbyid(opclass_object.opcowner) || ':' ||
      access_method.amname || ':' ||
      opclass_object.opcintype::regtype::text || ':' ||
      opclass_object.opckeytype::regtype::text || ':' ||
      family_namespace.nspname || '.' || family.opfname || ':' ||
      opclass_object.opcdefault::text
    from pg_opclass opclass_object
    join pg_namespace namespace on namespace.oid = opclass_object.opcnamespace
    join pg_am access_method on access_method.oid = opclass_object.opcmethod
    join pg_opfamily family on family.oid = opclass_object.opcfamily
    join pg_namespace family_namespace on family_namespace.oid = family.opfnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-opfamily:' || family.opfname || ':' ||
      pg_get_userbyid(family.opfowner) || ':' || access_method.amname
    from pg_opfamily family
    join pg_namespace namespace on namespace.oid = family.opfnamespace
    join pg_am access_method on access_method.oid = family.opfmethod
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-ts-config:' || config.cfgname || ':' ||
      pg_get_userbyid(config.cfgowner) || ':' ||
      parser_namespace.nspname || '.' || parser.prsname
    from pg_ts_config config
    join pg_namespace namespace on namespace.oid = config.cfgnamespace
    join pg_ts_parser parser on parser.oid = config.cfgparser
    join pg_namespace parser_namespace on parser_namespace.oid = parser.prsnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-ts-config-map:' || config.cfgname || ':' ||
      mapping.maptokentype::text || ':' || mapping.mapseqno::text || ':' ||
      dictionary_namespace.nspname || '.' || dictionary.dictname
    from pg_ts_config config
    join pg_namespace namespace on namespace.oid = config.cfgnamespace
    join pg_ts_config_map mapping on mapping.mapcfg = config.oid
    join pg_ts_dict dictionary on dictionary.oid = mapping.mapdict
    join pg_namespace dictionary_namespace
      on dictionary_namespace.oid = dictionary.dictnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-ts-dict:' || dictionary.dictname || ':' ||
      pg_get_userbyid(dictionary.dictowner) || ':' ||
      template_namespace.nspname || '.' || template.tmplname || ':' ||
      coalesce(dictionary.dictinitoption, '')
    from pg_ts_dict dictionary
    join pg_namespace namespace on namespace.oid = dictionary.dictnamespace
    join pg_ts_template template on template.oid = dictionary.dicttemplate
    join pg_namespace template_namespace
      on template_namespace.oid = template.tmplnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-ts-parser:' || parser.prsname || ':' ||
      parser.prsstart::regprocedure::text || ':' ||
      parser.prstoken::regprocedure::text || ':' ||
      parser.prsend::regprocedure::text || ':' ||
      parser.prsheadline::regprocedure::text || ':' ||
      parser.prslextype::regprocedure::text
    from pg_ts_parser parser
    join pg_namespace namespace on namespace.oid = parser.prsnamespace
    where namespace.nspname = 'symphony_staging'
    union all
    select
      'inventory-ts-template:' || template.tmplname || ':' ||
      coalesce(template.tmplinit::regprocedure::text, '') || ':' ||
      template.tmpllexize::regprocedure::text
    from pg_ts_template template
    join pg_namespace namespace on namespace.oid = template.tmplnamespace
    where namespace.nspname = 'symphony_staging'
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
      relation.relpersistence::text || ':' ||
      relation.relreplident::text || ':' ||
      relation.relrowsecurity::text || ':' ||
      relation.relforcerowsecurity::text || ':' ||
      relation.relhasrules::text || ':' ||
      relation.relhastriggers::text || ':' ||
      relation.relispopulated::text || ':' ||
      coalesce(relation.reloptions::text, '') || ':' ||
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
      index_state.indisreplident::text || ':' ||
      index_state.indisvalid::text || ':' ||
      index_state.indisready::text || ':' ||
      index_state.indislive::text || ':' ||
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
      attribute.attidentity::text || ':' ||
      attribute.attgenerated::text || ':' ||
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
      'constraint:' || relation.relname || ':' ||
      constraint_row.conname || ':' ||
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
      trigger_row.tgisinternal::text || ':' ||
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
      'rewrite:' || namespace.nspname || ':' || relation.relname || ':' ||
      rewrite.rulename || ':' || rewrite.ev_type::text || ':' ||
      rewrite.ev_enabled::text || ':' || rewrite.is_instead::text || ':' ||
      pg_get_ruledef(rewrite.oid, true)
    from pg_rewrite rewrite
    join pg_class relation on relation.oid = rewrite.ev_class
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('symphony_staging', 'symphony_production')
    union all
    select 'production-function:' || procedure.oid::regprocedure::text || ':' ||
      pg_get_functiondef(procedure.oid)
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-type:' || type_object.typname || ':' ||
      type_object.typtype::text || ':' || type_object.typcategory::text
    from pg_type type_object
    join pg_namespace namespace on namespace.oid = type_object.typnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-operator:' || operator_object.oid::regoperator::text
    from pg_operator operator_object
    join pg_namespace namespace on namespace.oid = operator_object.oprnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-collation:' || collation_object.collname
    from pg_collation collation_object
    join pg_namespace namespace on namespace.oid = collation_object.collnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-conversion:' || conversion_object.conname
    from pg_conversion conversion_object
    join pg_namespace namespace on namespace.oid = conversion_object.connamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-opclass:' || opclass_object.opcname
    from pg_opclass opclass_object
    join pg_namespace namespace on namespace.oid = opclass_object.opcnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-opfamily:' || family.opfname
    from pg_opfamily family
    join pg_namespace namespace on namespace.oid = family.opfnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-ts-config:' || object.cfgname
    from pg_ts_config object
    join pg_namespace namespace on namespace.oid = object.cfgnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-ts-dict:' || object.dictname
    from pg_ts_dict object
    join pg_namespace namespace on namespace.oid = object.dictnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-ts-parser:' || object.prsname
    from pg_ts_parser object
    join pg_namespace namespace on namespace.oid = object.prsnamespace
    where namespace.nspname = 'symphony_production'
    union all
    select 'production-ts-template:' || object.tmplname
    from pg_ts_template object
    join pg_namespace namespace on namespace.oid = object.tmplnamespace
    where namespace.nspname = 'symphony_production'
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
drop function if exists symphony_staging.retire_node_instance(uuid, uuid, uuid);
drop function if exists symphony_staging.reenroll_node(uuid, uuid);
drop function if exists symphony_staging.revoke_node(uuid, uuid);
drop function if exists symphony_staging.rotate_node_credential(uuid, uuid);
drop function if exists symphony_staging.provision_node(uuid, text, text, text);
drop table if exists symphony_staging.active_node_instances;
drop table if exists symphony_staging.node_instance_history;
drop table if exists symphony_staging.node_lifecycle_operations;
drop table if exists symphony_staging.node_login_principals;
drop table if exists symphony_staging.node_principal_history;
drop table if exists symphony_staging.node_enrollment_contract_manifest;

grant select, insert, update on
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments
  to symphony_staging_provisioner;
grant insert on symphony_staging.foundation_audit_events
  to symphony_staging_provisioner;
grant usage, select on sequence
  symphony_staging.foundation_audit_events_audit_id_seq
  to symphony_staging_provisioner;

create policy provisioner_manage_contract_versions
  on symphony_staging.contract_versions
  for all
  to symphony_staging_provisioner
  using (contract_name not like 'aro-163-created-role:%')
  with check (contract_name not like 'aro-163-created-role:%');
create policy provisioner_manage_nodes
  on symphony_staging.nodes
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);
create policy provisioner_manage_node_bindings
  on symphony_staging.node_bindings
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);
create policy provisioner_manage_routing_assignments
  on symphony_staging.routing_assignments
  for all
  to symphony_staging_provisioner
  using (true)
  with check (true);
create policy provisioner_insert_audit_events
  on symphony_staging.foundation_audit_events
  for insert
  to symphony_staging_provisioner
  with check (true);

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
