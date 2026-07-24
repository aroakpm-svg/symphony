begin;

do $$
begin
  if exists (
    select 1
    from symphony_staging.node_login_principals
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 rollback refused while provisioned node principals exist';
  end if;
end
$$;

drop function if exists symphony_staging.authenticate_node(uuid, uuid);
drop function if exists symphony_staging.revoke_node(uuid);
drop function if exists symphony_staging.rotate_node_credential(uuid);
drop function if exists symphony_staging.provision_node(text);
drop table if exists symphony_staging.node_login_principals;

update symphony_staging.contract_versions
set
  contract_version = 2,
  migration_name = '20260724000000_aro_168_staging_reconciliation'
where contract_name = 'node-identity-routing-foundation'
  and contract_version = 3
  and migration_name = '20260724010000_aro_169_node_enrollment';

commit;
