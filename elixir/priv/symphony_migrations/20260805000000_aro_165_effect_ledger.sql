begin;

create table symphony_staging.effect_operations (
  operation_id text primary key,
  effect_type text not null check (effect_type in (
    'linear_comment', 'github_comment', 'git_commit', 'git_push',
    'github_pr_create', 'github_pr_update', 'linear_state'
  )),
  request_fingerprint text not null,
  issue_id text not null,
  claim_id uuid not null,
  generation bigint not null check (generation > 0),
  status text not null default 'pending'
    check (status in ('pending', 'succeeded', 'failed-no-effect', 'unknown')),
  native_resource jsonb,
  failure_reason text,
  attempt_id uuid,
  attempt_expires_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  reconciled_at timestamptz,
  constraint effect_operation_claim_fk
    foreign key (issue_id) references symphony_staging.issue_claims(issue_id)
);

alter table symphony_staging.effect_operations enable row level security;

revoke all on table symphony_staging.effect_operations
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.begin_effect(
  requested_operation_id text,
  requested_effect_type text,
  requested_fingerprint text,
  requested_issue_id text,
  requested_claim_id uuid,
  requested_generation bigint,
  requested_node_id uuid,
  requested_node_instance_id uuid,
  requested_attempt_id uuid,
  requested_attempt_lease_ms integer
)
returns table (status text, native_resource jsonb, attempt_id uuid)
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  existing symphony_staging.effect_operations%rowtype;
begin
  if requested_operation_id is null or btrim(requested_operation_id) = ''
     or requested_fingerprint is null or btrim(requested_fingerprint) = ''
     or requested_attempt_id is null
     or requested_attempt_lease_ms is null or requested_attempt_lease_ms <= 0 then
    raise exception using errcode = '22023', message = 'operation, fingerprint, and attempt lease are required';
  end if;

  if requested_effect_type not in (
    'linear_comment', 'github_comment', 'git_commit', 'git_push',
    'github_pr_create', 'github_pr_update', 'linear_state'
  ) then
    raise exception using errcode = '22023', message = 'unsupported effect type';
  end if;

  perform 1
    from symphony_staging.issue_claims claims
    join symphony_staging.nodes nodes on nodes.node_id = claims.node_id
    join symphony_staging.node_login_principals principals
      on principals.node_id = nodes.node_id
     and principals.login_role = session_user
     and principals.revoked_at is null
    join symphony_staging.active_node_instances instances
      on instances.node_id = claims.node_id
     and instances.node_instance_id = claims.node_instance_id
    where claims.issue_id = requested_issue_id
      and claims.claim_id = requested_claim_id
      and claims.generation = requested_generation
      and claims.node_id = requested_node_id
      and claims.node_instance_id = requested_node_instance_id
      and nodes.status = 'active'
      and claims.completed_at is null
      and claims.released_at is null
      and claims.lease_expires_at > clock_timestamp()
    for update of claims;

  if not found then
    raise exception using errcode = '55000', message = 'effect requires a matching active claim generation';
  end if;

  select operations.* into existing
  from symphony_staging.effect_operations operations
  where operations.operation_id = requested_operation_id
  for update;

  if found then
    if existing.effect_type <> requested_effect_type
       or existing.request_fingerprint <> requested_fingerprint
       or existing.issue_id <> requested_issue_id
       or existing.claim_id <> requested_claim_id
       or existing.generation <> requested_generation then
      raise exception using errcode = '55000', message = 'operation identity or request fingerprint mismatch';
    end if;

    if existing.status = 'pending'
       and existing.attempt_id <> requested_attempt_id
       and existing.attempt_expires_at > clock_timestamp() then
      return query select 'in-flight'::text, existing.native_resource, null::uuid;
      return;
    end if;

    if existing.status = 'pending'
       and (existing.attempt_id = requested_attempt_id
            or existing.attempt_expires_at is null
            or existing.attempt_expires_at <= clock_timestamp()) then
      update symphony_staging.effect_operations operations
      set attempt_id = requested_attempt_id,
          attempt_expires_at = clock_timestamp() + make_interval(secs => requested_attempt_lease_ms / 1000.0),
          updated_at = clock_timestamp()
      where operations.operation_id = requested_operation_id;

      return query select 'pending'::text, existing.native_resource, requested_attempt_id;
      return;
    end if;

    if existing.status = 'failed-no-effect' then
      update symphony_staging.effect_operations operations
      set status = 'pending', failure_reason = null,
          attempt_id = requested_attempt_id,
          attempt_expires_at = clock_timestamp() + make_interval(secs => requested_attempt_lease_ms / 1000.0),
          updated_at = clock_timestamp()
      where operations.operation_id = requested_operation_id;

      return query select 'pending'::text, existing.native_resource, requested_attempt_id;
      return;
    end if;

    return query select existing.status, existing.native_resource, null::uuid;
    return;
  end if;

  insert into symphony_staging.effect_operations (
    operation_id, effect_type, request_fingerprint, issue_id, claim_id, generation,
    attempt_id, attempt_expires_at
  ) values (
    requested_operation_id, requested_effect_type, requested_fingerprint,
    requested_issue_id, requested_claim_id, requested_generation,
    requested_attempt_id,
    clock_timestamp() + make_interval(secs => requested_attempt_lease_ms / 1000.0)
  );

  return query select 'pending'::text, null::jsonb, requested_attempt_id;
end
$$;

create or replace function symphony_staging.finish_effect(
  requested_operation_id text,
  requested_fingerprint text,
  requested_attempt_id uuid,
  requested_status text,
  requested_native_resource jsonb,
  requested_failure_reason text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  changed integer;
begin
  if requested_status not in ('succeeded', 'failed-no-effect', 'unknown') then
    raise exception using errcode = '22023', message = 'invalid terminal effect status';
  end if;

  update symphony_staging.effect_operations operations
  set status = requested_status,
      native_resource = requested_native_resource,
      failure_reason = requested_failure_reason,
      attempt_id = null,
      attempt_expires_at = null,
      updated_at = clock_timestamp()
  where operations.operation_id = requested_operation_id
    and operations.request_fingerprint = requested_fingerprint
    and operations.status = 'pending'
    and operations.attempt_id = requested_attempt_id
    and operations.attempt_expires_at > clock_timestamp();
  get diagnostics changed = row_count;

  return changed = 1;
end
$$;

create or replace function symphony_staging.reconcile_effect(
  requested_operation_id text,
  requested_fingerprint text,
  requested_status text,
  requested_native_resource jsonb
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  changed integer;
begin
  if requested_status not in ('succeeded', 'failed-no-effect') then
    raise exception using errcode = '22023', message = 'reconciliation must produce a definite result';
  end if;

  update symphony_staging.effect_operations operations
  set status = requested_status,
      native_resource = requested_native_resource,
      failure_reason = null,
      attempt_id = null,
      attempt_expires_at = null,
      reconciled_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where operations.operation_id = requested_operation_id
    and operations.request_fingerprint = requested_fingerprint
    and operations.status in ('pending', 'unknown');
  get diagnostics changed = row_count;

  return changed = 1;
end
$$;

revoke all on function
  symphony_staging.begin_effect(text, text, text, text, uuid, bigint, uuid, uuid, uuid, integer),
  symphony_staging.finish_effect(text, text, uuid, text, jsonb, text),
  symphony_staging.reconcile_effect(text, text, text, jsonb)
  from public, anon, authenticated, service_role, symphony_staging_provisioner;

grant execute on function
  symphony_staging.begin_effect(text, text, text, text, uuid, bigint, uuid, uuid, uuid, integer),
  symphony_staging.finish_effect(text, text, uuid, text, jsonb, text),
  symphony_staging.reconcile_effect(text, text, text, jsonb)
  to symphony_staging_runtime;

create or replace function symphony_staging.grant_effect_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.begin_effect(text, text, text, text, uuid, bigint, uuid, uuid, uuid, integer), '
    'symphony_staging.finish_effect(text, text, uuid, text, jsonb, text), '
    'symphony_staging.reconcile_effect(text, text, text, jsonb) to %I',
    new.login_role
  );
  return new;
end
$$;

revoke all on function symphony_staging.grant_effect_api_to_node_login()
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop trigger if exists grant_effect_api_to_node_login
  on symphony_staging.node_login_principals;
create trigger grant_effect_api_to_node_login
after insert or update of login_role on symphony_staging.node_login_principals
for each row execute function symphony_staging.grant_effect_api_to_node_login();

do $$
declare
  principal record;
begin
  for principal in select login_role from symphony_staging.node_login_principals
  loop
    execute format(
      'grant execute on function '
      'symphony_staging.begin_effect(text, text, text, text, uuid, bigint, uuid, uuid, uuid, integer), '
      'symphony_staging.finish_effect(text, text, uuid, text, jsonb, text), '
      'symphony_staging.reconcile_effect(text, text, text, jsonb) to %I',
      principal.login_role
    );
  end loop;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'effect-ledger', 1, '20260805000000_aro_165_effect_ledger'
)
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
