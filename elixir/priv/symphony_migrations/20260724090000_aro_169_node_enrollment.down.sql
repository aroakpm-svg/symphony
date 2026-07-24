begin;
delete from symphony_staging.contract_versions
 where contract_name='node-enrollment-authentication' and contract_version=1;
drop function symphony_staging.node_instance_authorized(uuid,uuid);
drop function symphony_staging.authenticate_node_startup(uuid,text,integer,uuid);
drop function symphony_staging.change_node_credential(uuid,uuid,uuid,text,text,integer);
drop function symphony_staging.provision_node(uuid,uuid,uuid,text,text,integer,text,text,bigint);
drop function symphony_staging.constant_time_equal(text,text);
drop function symphony_staging.credential_verifier(text);
drop table symphony_staging.node_instances;
drop table symphony_staging.node_provisioning_operations;
commit;
