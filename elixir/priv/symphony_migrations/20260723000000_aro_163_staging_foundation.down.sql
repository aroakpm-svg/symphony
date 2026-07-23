begin;

create temporary table if not exists aro_163_roles_to_drop (
  role_name name primary key
) on commit drop;

insert into aro_163_roles_to_drop (role_name)
select replace(contract_name, 'aro-163-created-role:', '')::name
from symphony_staging.contract_versions
where contract_name in (
  'aro-163-created-role:symphony_staging_runtime',
  'aro-163-created-role:symphony_staging_provisioner'
);

drop table if exists symphony_staging.foundation_audit_events;
drop table if exists symphony_staging.routing_assignments;
drop table if exists symphony_staging.node_bindings;
drop table if exists symphony_staging.nodes;
drop table if exists symphony_staging.contract_versions;

drop function if exists symphony_staging.enforce_routing_revision();
drop function if exists symphony_staging.enforce_node_binding_transition();
drop function if exists symphony_staging.enforce_node_transition();

do $$
declare
  role_name name;
begin
  for role_name in select roles.role_name from aro_163_roles_to_drop roles
  loop
    execute format('revoke all on schema symphony_staging from %I', role_name);
    execute format('revoke %I from postgres', role_name);
    execute format('drop role %I', role_name);
  end loop;
end
$$;

commit;
