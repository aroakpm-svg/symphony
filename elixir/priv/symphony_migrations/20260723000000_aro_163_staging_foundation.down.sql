begin;

drop table if exists symphony_staging.foundation_audit_events;
drop table if exists symphony_staging.routing_assignments;
drop table if exists symphony_staging.node_bindings;
drop table if exists symphony_staging.nodes;
drop table if exists symphony_staging.contract_versions;

drop function if exists symphony_staging.enforce_routing_revision();
drop function if exists symphony_staging.enforce_node_binding_transition();
drop function if exists symphony_staging.enforce_node_transition();

revoke all on schema symphony_staging
  from symphony_staging_runtime, symphony_staging_provisioner;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'symphony_staging_runtime') then
    drop role symphony_staging_runtime;
  end if;

  if exists (select 1 from pg_roles where rolname = 'symphony_staging_provisioner') then
    drop role symphony_staging_provisioner;
  end if;
end
$$;

commit;
