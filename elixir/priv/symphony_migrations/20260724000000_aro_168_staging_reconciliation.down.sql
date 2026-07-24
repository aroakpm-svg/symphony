begin;

do $aro_168_rollback_gate$
begin
  if (select count(*) from symphony_staging.nodes) <> 0
     or (select count(*) from symphony_staging.node_bindings) <> 0
     or (select count(*) from symphony_staging.routing_assignments) <> 0
     or (select count(*) from symphony_staging.foundation_audit_events) <> 0
     or (select rolconfig from pg_roles where rolname = 'symphony_staging_runtime') is not null
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
    raise exception 'ARO-168 rollback refused unexpected v2 state';
  end if;
end
$aro_168_rollback_gate$;

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

commit;
