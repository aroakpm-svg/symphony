begin;

create table if not exists symphony_staging.node_provisioning_operations (
  operation_id uuid primary key,
  operation_type text not null check (operation_type in ('provision','rotate','revoke','reenroll')),
  node_id uuid not null,
  request_fingerprint text not null check (request_fingerprint ~ '^[a-f0-9]{64}$'),
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);

create table if not exists symphony_staging.node_instances (
  node_instance_id uuid primary key,
  node_id uuid not null references symphony_staging.nodes(node_id) on delete restrict,
  binding_id uuid not null references symphony_staging.node_bindings(binding_id) on delete restrict,
  credential_version integer not null,
  status text not null check (status in ('active','superseded','revoked')),
  started_at timestamptz not null default clock_timestamp(),
  invalidated_at timestamptz
);
create unique index if not exists node_instances_one_active_per_node
  on symphony_staging.node_instances(node_id) where status = 'active';

revoke all on symphony_staging.node_provisioning_operations,
  symphony_staging.node_instances from public, anon, authenticated, service_role,
  symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.credential_verifier(credential text)
returns text language sql immutable strict security invoker
set search_path = pg_catalog, extensions
return encode(extensions.digest(convert_to(credential, 'UTF8'), 'sha256'), 'hex');

create or replace function symphony_staging.constant_time_equal(left_value text, right_value text)
returns boolean language plpgsql immutable strict security invoker
set search_path = pg_catalog
as $$
declare difference integer := length(left_value) # length(right_value); position integer;
begin
  for position in 1..greatest(length(left_value), length(right_value)) loop
    difference := difference | (
      get_byte(convert_to(left_value,'UTF8'), least(position,length(left_value))-1) #
      get_byte(convert_to(right_value,'UTF8'), least(position,length(right_value))-1));
  end loop;
  return difference = 0;
end $$;

create or replace function symphony_staging.provision_node(
  operation_id uuid, node_id uuid, binding_id uuid, display_alias text,
  credential text, credential_version integer, issue_id text,
  routing_policy text, routing_revision bigint
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, symphony_staging, extensions
as $$
declare fingerprint text; saved jsonb;
begin
  if credential is null or length(credential) < 32 or display_alias is null
     or btrim(display_alias) = '' then raise exception 'invalid provisioning input'; end if;
  fingerprint := symphony_staging.credential_verifier(
    concat_ws('|', node_id, binding_id, display_alias, credential_version,
      issue_id, routing_policy, routing_revision));
  select result into saved from symphony_staging.node_provisioning_operations o
    where o.operation_id = provision_node.operation_id
      and o.request_fingerprint = fingerprint;
  if found then return saved; end if;
  if exists (select 1 from symphony_staging.node_provisioning_operations o
             where o.operation_id = provision_node.operation_id) then
    raise exception 'operation id conflict';
  end if;
  insert into symphony_staging.nodes(node_id,display_alias,status,credential_version)
    values(node_id,btrim(display_alias),'active',credential_version);
  insert into symphony_staging.node_bindings(
    binding_id,node_id,environment,status,credential_version,credential_verifier,activated_at)
    values(binding_id,node_id,'staging','active',credential_version,
      symphony_staging.credential_verifier(credential),clock_timestamp());
  insert into symphony_staging.routing_assignments(
    issue_id,routing_policy,target_node_id,routing_revision,contract_version)
    values(issue_id,routing_policy,
      case when routing_policy='unassigned' then null else node_id end,
      routing_revision,2);
  saved := jsonb_build_object('nodeId',node_id,'bindingId',binding_id,
    'credentialVersion',credential_version,'operationId',operation_id);
  insert into symphony_staging.foundation_audit_events(
    event_type,node_id,binding_id,issue_id,routing_revision,credential_version,result,reason_code,
    details) values('node-provisioned',node_id,binding_id,issue_id,routing_revision,
      credential_version,'accepted','provisioned',
      jsonb_build_object('alias',btrim(display_alias),'operationId',operation_id));
  insert into symphony_staging.node_provisioning_operations
    values(operation_id,'provision',node_id,fingerprint,saved,clock_timestamp());
  return saved;
end $$;

create or replace function symphony_staging.authenticate_node_startup(
  node_id uuid, credential text, credential_version integer, node_instance_id uuid
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, symphony_staging, extensions
as $$
declare binding symphony_staging.node_bindings%rowtype; node_status text;
begin
  select n.status,b.* into node_status,binding
  from symphony_staging.nodes n join symphony_staging.node_bindings b using(node_id)
  where n.node_id=authenticate_node_startup.node_id and b.environment='staging'
    and b.status='active' and b.credential_version=authenticate_node_startup.credential_version;
  if not found or node_status <> 'active'
     or not symphony_staging.constant_time_equal(binding.credential_verifier,
       symphony_staging.credential_verifier(authenticate_node_startup.credential)) then
    raise exception 'authentication rejected';
  end if;
  update symphony_staging.node_instances set status='superseded',
    invalidated_at=clock_timestamp() where node_id=authenticate_node_startup.node_id
    and status='active';
  insert into symphony_staging.node_instances(
    node_instance_id,node_id,binding_id,credential_version,status)
    values(node_instance_id,node_id,binding.binding_id,credential_version,'active');
  return jsonb_build_object('authenticated',true,'nodeId',node_id,
    'nodeInstanceId',node_instance_id,'credentialVersion',credential_version);
end $$;

create or replace function symphony_staging.change_node_credential(
  operation_id uuid, node_id uuid, binding_id uuid, operation_type text,
  credential text, credential_version integer
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, symphony_staging, extensions
as $$
declare fingerprint text; saved jsonb; current_binding symphony_staging.node_bindings%rowtype;
begin
  if operation_type not in ('rotate','revoke','reenroll') then
    raise exception 'invalid credential operation';
  end if;
  fingerprint := symphony_staging.credential_verifier(
    concat_ws('|',node_id,binding_id,operation_type,credential_version));
  select result into saved from symphony_staging.node_provisioning_operations o
    where o.operation_id=change_node_credential.operation_id
      and o.request_fingerprint=fingerprint;
  if found then return saved; end if;
  if exists(select 1 from symphony_staging.node_provisioning_operations o
            where o.operation_id=change_node_credential.operation_id) then
    raise exception 'operation id conflict';
  end if;
  select * into strict current_binding from symphony_staging.node_bindings b
    where b.node_id=change_node_credential.node_id and b.environment='staging'
      and b.status='active' for update;
  update symphony_staging.node_bindings set status='revoked',revoked_at=clock_timestamp()
    where node_bindings.binding_id=current_binding.binding_id;
  update symphony_staging.node_instances set status='revoked',invalidated_at=clock_timestamp()
    where node_instances.node_id=change_node_credential.node_id and status='active';
  if operation_type='revoke' then
    update symphony_staging.nodes set status='disabled',revoked_at=clock_timestamp(),
      updated_at=clock_timestamp() where nodes.node_id=change_node_credential.node_id;
  else
    if credential is null or length(credential)<32
       or credential_version<=current_binding.credential_version then
      raise exception 'invalid replacement credential';
    end if;
    insert into symphony_staging.node_bindings(
      binding_id,node_id,environment,status,credential_version,credential_verifier,activated_at)
      values(binding_id,node_id,'staging','active',credential_version,
        symphony_staging.credential_verifier(credential),clock_timestamp());
    update symphony_staging.nodes set status='active',
      credential_version=change_node_credential.credential_version,
      revoked_at=null,rotated_at=clock_timestamp(),updated_at=clock_timestamp()
      where nodes.node_id=change_node_credential.node_id;
  end if;
  saved:=jsonb_build_object('nodeId',node_id,'bindingId',
    case when operation_type='revoke' then current_binding.binding_id else binding_id end,
    'credentialVersion',credential_version,'operationId',operation_id,'operation',operation_type);
  insert into symphony_staging.foundation_audit_events(
    event_type,node_id,binding_id,credential_version,result,reason_code,details)
    values('node-credential-'||operation_type,node_id,
      case when operation_type='revoke' then current_binding.binding_id else binding_id end,
      credential_version,'accepted',operation_type,
      jsonb_build_object('operationId',operation_id));
  insert into symphony_staging.node_provisioning_operations
    values(operation_id,operation_type,node_id,fingerprint,saved,clock_timestamp());
  return saved;
end $$;

create or replace function symphony_staging.node_instance_authorized(
  node_id uuid, node_instance_id uuid
) returns boolean language sql stable security definer
set search_path = pg_catalog, symphony_staging
return exists(select 1 from symphony_staging.node_instances i
  join symphony_staging.nodes n using(node_id)
  join symphony_staging.node_bindings b on b.binding_id=i.binding_id
  where i.node_id=node_instance_authorized.node_id
    and i.node_instance_id=node_instance_authorized.node_instance_id
    and i.status='active' and n.status='active' and b.status='active'
    and b.credential_version=i.credential_version);

revoke all on function symphony_staging.credential_verifier(text) from public, anon, authenticated, service_role;
revoke all on function symphony_staging.constant_time_equal(text,text) from public, anon, authenticated, service_role;
revoke all on function symphony_staging.provision_node(uuid,uuid,uuid,text,text,integer,text,text,bigint) from public, anon, authenticated, service_role;
revoke all on function symphony_staging.authenticate_node_startup(uuid,text,integer,uuid) from public, anon, authenticated, service_role;
revoke all on function symphony_staging.node_instance_authorized(uuid,uuid) from public, anon, authenticated, service_role;
revoke all on function symphony_staging.change_node_credential(uuid,uuid,uuid,text,text,integer) from public, anon, authenticated, service_role;
grant execute on function symphony_staging.provision_node(uuid,uuid,uuid,text,text,integer,text,text,bigint) to symphony_staging_provisioner;
grant execute on function symphony_staging.change_node_credential(uuid,uuid,uuid,text,text,integer) to symphony_staging_provisioner;
grant execute on function symphony_staging.authenticate_node_startup(uuid,text,integer,uuid),
  symphony_staging.node_instance_authorized(uuid,uuid) to symphony_staging_runtime;

insert into symphony_staging.contract_versions(contract_name,contract_version,migration_name)
values('node-enrollment-authentication',1,'20260724090000_aro_169_node_enrollment')
on conflict (contract_name) do nothing;
commit;
