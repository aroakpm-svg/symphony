begin;

drop trigger if exists grant_finding_readback_api_to_node_login
  on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_finding_readback_api_to_node_login();

delete from symphony_staging.contract_versions
where contract_name = 'finding-effect-readback';

revoke all on function
  symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid)
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop function if exists
  symphony_staging.list_effect_operations(text, uuid, bigint, uuid, uuid);

commit;
