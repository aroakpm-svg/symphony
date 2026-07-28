#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
migrations_dir="$root_dir/elixir/priv/symphony_migrations"
admin_url="${TEST_DATABASE_URL:?TEST_DATABASE_URL is required}"
root_url="${TEST_ROOT_DATABASE_URL:?TEST_ROOT_DATABASE_URL is required}"

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -d "$admin_url" "$@"
}

psql_root() {
  psql -X -q -v ON_ERROR_STOP=1 -d "$root_url" "$@"
}

set_pgcrypto_live_acl() {
  psql_root <<'SQL'
alter function extensions.gen_random_bytes(integer) owner to postgres;
alter function extensions.digest(text, text) owner to postgres;
SQL
  psql_admin <<'SQL'
grant execute on function extensions.gen_random_bytes(integer),
  extensions.digest(text, text) to dashboard_user;
grant execute on function extensions.gen_random_bytes(integer),
  extensions.digest(text, text) to postgres with grant option;
SQL
}

psql_root <<'SQL'
create role postgres login superuser createrole createdb replication bypassrls
  password 'disposable';
alter database postgres owner to postgres;
SQL

psql_admin <<'SQL'
create schema extensions;
create extension pgcrypto with schema extensions;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema symphony_production;
SQL

psql_root -f "$root_dir/.github/fixtures/aro-169-supabase-managed-event-triggers.sql"
set_pgcrypto_live_acl

psql_admin <<'SQL'
do $$
begin
  if exists (
    with expected(function_name, grantor, grantee, privilege_type, is_grantable) as (
      values
        ('digest(text, text)', 'postgres', 'pseudo', 'EXECUTE', false),
        ('digest(text, text)', 'postgres', 'role:dashboard_user', 'EXECUTE', false),
        ('digest(text, text)', 'postgres', 'role:postgres', 'EXECUTE', true),
        ('gen_random_bytes(integer)', 'postgres', 'pseudo', 'EXECUTE', false),
        ('gen_random_bytes(integer)', 'postgres', 'role:dashboard_user', 'EXECUTE', false),
        ('gen_random_bytes(integer)', 'postgres', 'role:postgres', 'EXECUTE', true)
    ),
    actual as (
      select procedure.proname || '(' ||
               pg_catalog.pg_get_function_identity_arguments(procedure.oid) || ')',
             grantor.rolname,
             case when acl.grantee = 0 then 'pseudo'
                  else 'role:' || grantee.rolname end,
             acl.privilege_type, acl.is_grantable
      from pg_proc procedure
      cross join lateral aclexplode(procedure.proacl) acl
      join pg_roles grantor on grantor.oid = acl.grantor
      left join pg_roles grantee on grantee.oid = acl.grantee
      where procedure.oid in (
        'extensions.gen_random_bytes(integer)'::regprocedure,
        'extensions.digest(text,text)'::regprocedure
      )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception 'pgcrypto ACL fixture differs from live catalog facts';
  end if;
end
$$;
SQL

psql_admin <<'SQL'
do $$
begin
  if exists (
    with expected(trigger_name, grantor, grantee, privilege_type, is_grantable) as (
      values
        ('issue_graphql_placeholder', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('issue_graphql_placeholder', 'supabase_admin', 'role:postgres', 'EXECUTE', true),
        ('issue_graphql_placeholder', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', false),
        ('issue_pg_cron_access', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('issue_pg_cron_access', 'supabase_admin', 'role:dashboard_user', 'EXECUTE', false),
        ('issue_pg_cron_access', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', true),
        ('issue_pg_graphql_access', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('issue_pg_graphql_access', 'supabase_admin', 'role:postgres', 'EXECUTE', true),
        ('issue_pg_graphql_access', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', false),
        ('issue_pg_net_access', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('issue_pg_net_access', 'supabase_admin', 'role:dashboard_user', 'EXECUTE', false),
        ('issue_pg_net_access', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', true),
        ('pgrst_ddl_watch', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('pgrst_ddl_watch', 'supabase_admin', 'role:postgres', 'EXECUTE', true),
        ('pgrst_ddl_watch', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', false),
        ('pgrst_drop_watch', 'supabase_admin', 'pseudo', 'EXECUTE', false),
        ('pgrst_drop_watch', 'supabase_admin', 'role:postgres', 'EXECUTE', true),
        ('pgrst_drop_watch', 'supabase_admin', 'role:supabase_admin', 'EXECUTE', false)
    ),
    actual as (
      select event_trigger.evtname, grantor.rolname,
             case when acl.grantee = 0 then 'pseudo' else 'role:' || grantee.rolname end,
             acl.privilege_type, acl.is_grantable
      from pg_event_trigger event_trigger
      join pg_proc procedure on procedure.oid = event_trigger.evtfoid
      cross join lateral aclexplode(procedure.proacl) acl
      join pg_roles grantor on grantor.oid = acl.grantor
      left join pg_roles grantee on grantee.oid = acl.grantee
      where event_trigger.evtname in (
        'issue_graphql_placeholder', 'issue_pg_cron_access',
        'issue_pg_graphql_access', 'issue_pg_net_access',
        'pgrst_ddl_watch', 'pgrst_drop_watch'
      )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception 'managed event-trigger ACL fixture differs from live facts';
  end if;
end
$$;
SQL

psql_admin <<'SQL'
create role "PUBLIC>EXECUTE>false,supabase_admin>postgres" nologin;
create role "quote""slash\角色,>" nologin;

do $$
declare
  old_a text := 'supabase_admin>PUBLIC>EXECUTE>false,supabase_admin>postgres>EXECUTE>true';
  old_b text := 'supabase_admin>PUBLIC>EXECUTE>false,supabase_admin>postgres>EXECUTE>true';
  encoded_a text;
  encoded_b text;
begin
  encoded_a := encode(convert_to('PUBLIC', 'UTF8'), 'hex') || '>' ||
    encode(convert_to('EXECUTE', 'UTF8'), 'hex') || '>false,' ||
    encode(convert_to('postgres', 'UTF8'), 'hex') || '>' ||
    encode(convert_to('EXECUTE', 'UTF8'), 'hex') || '>true';
  encoded_b := encode(convert_to(
      'PUBLIC>EXECUTE>false,supabase_admin>postgres', 'UTF8'
    ), 'hex') || '>' || encode(convert_to('EXECUTE', 'UTF8'), 'hex') || '>true';

  if old_a <> old_b or encoded_a = encoded_b then
    raise exception 'ACL encoding collision regression failed';
  end if;
  if encode(convert_to('quote"slash\角色,>', 'UTF8'), 'hex') !~ '^[0-9a-f]+$' then
    raise exception 'ACL UTF-8 encoding is not bytewise canonical';
  end if;
end
$$;

drop role "quote""slash\角色,>";
drop role "PUBLIC>EXECUTE>false,supabase_admin>postgres";
SQL

psql_admin -f "$migrations_dir/20260723000000_aro_163_staging_foundation.sql"

psql_admin <<'SQL'
delete from symphony_staging.contract_versions
where contract_name like 'aro-163-created-role:%';
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
SQL

psql_root <<'SQL'
revoke symphony_staging_runtime, symphony_staging_provisioner from postgres;
alter role supabase_admin superuser;
set role supabase_admin;
grant symphony_staging_runtime, symphony_staging_provisioner to postgres
  with admin option, inherit false, set false;
reset role;
alter role supabase_admin nosuperuser;
SQL
psql_admin -c "
  grant symphony_staging_runtime, symphony_staging_provisioner to postgres
    with admin false, inherit true, set true
    granted by postgres;
"
psql_root -c "alter role postgres nosuperuser;"

psql_admin -f "$migrations_dir/20260724000000_aro_168_staging_reconciliation.sql"
psql_root -c "alter role postgres superuser;"

psql_root <<'SQL'
create function public.aro169_grant_drift()
returns event_trigger
language plpgsql
as $$
begin
  execute 'grant usage on schema symphony_staging to service_role';
  if to_regclass('symphony_staging.node_login_principals') is not null then
    execute 'grant select on symphony_staging.node_login_principals to service_role';
  end if;
end
$$;
create event trigger aro169_grant_drift
  on ddl_command_end
  execute function public.aro169_grant_drift();
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted an enabled event trigger" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_root <<'SQL'
drop event trigger aro169_grant_drift;
drop function public.aro169_grant_drift();
revoke usage on schema symphony_staging from service_role;
SQL

if psql_root \
  -c "begin; drop event trigger issue_pg_net_access; create event trigger issue_pg_net_access on ddl_command_end execute function extensions.pgrst_ddl_watch();" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted a same-name managed trigger replacement" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"

if psql_root \
  -c "begin; alter event trigger pgrst_ddl_watch owner to postgres;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger owner drift" >&2
  exit 1
fi

if psql_root \
  -c "begin; create or replace function extensions.pgrst_drop_watch() returns event_trigger language plpgsql as 'begin null; end';" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger definition drift" >&2
  exit 1
fi

if psql_root \
  -c "begin; grant execute on function extensions.pgrst_drop_watch() to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger function ACL drift" >&2
  exit 1
fi

psql_admin -c 'create role "PUBLIC" nologin;' >/dev/null
if psql_admin \
  -c 'begin; set local role supabase_admin; revoke execute on function extensions.pgrst_drop_watch() from public; grant execute on function extensions.pgrst_drop_watch() to "PUBLIC";' \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo 'v3 apply unexpectedly conflated pseudo-PUBLIC with role "PUBLIC"' >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c 'drop role "PUBLIC";' >/dev/null

if psql_admin \
  -c "begin; revoke grant option for execute on function extensions.pgrst_drop_watch() from postgres;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger function grant-option drift" >&2
  exit 1
fi

if psql_admin \
  -c "begin; set role postgres; grant execute on function extensions.pgrst_drop_watch() to authenticated; reset role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger function grantor drift" >&2
  exit 1
fi

if psql_admin \
  -c "begin; alter function extensions.pgrst_drop_watch() set search_path = pg_catalog;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger function config drift" >&2
  exit 1
fi

if psql_admin \
  -c "begin; alter function extensions.pgrst_drop_watch() cost 101;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted managed trigger function cost drift" >&2
  exit 1
fi

psql_admin -c "
  alter role symphony_staging_provisioner in database postgres
    set statement_timeout = '1ms';
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted database-scoped managed-role settings" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  alter role symphony_staging_provisioner in database postgres
    reset statement_timeout;
" >/dev/null

psql_admin <<'SQL'
create view public.aro169_external_nodes
with (security_invoker = false)
as select node_id, display_alias from symphony_staging.nodes;
grant select on public.aro169_external_nodes to service_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted an external dependent view" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin <<'SQL'
revoke select on public.aro169_external_nodes from service_role;
drop view public.aro169_external_nodes;
SQL

psql_admin <<'SQL'
create table public.aro169_external_binding_refs (
  node_id uuid not null,
  environment text not null,
  credential_version integer not null,
  constraint aro169_external_binding_fk
    foreign key (node_id, environment, credential_version)
    references symphony_staging.node_bindings(
      node_id, environment, credential_version
    )
    match full
    on update restrict
    on delete cascade
    deferrable initially deferred
    not valid
);
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted a cross-schema composite foreign key" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "drop table public.aro169_external_binding_refs;" >/dev/null

psql_admin <<'SQL'
create table public.aro169_partitioned_binding_refs (
  node_id uuid not null,
  environment text not null,
  credential_version integer not null
) partition by hash (node_id);
create table public.aro169_partitioned_binding_refs_p0
  partition of public.aro169_partitioned_binding_refs
  for values with (modulus 2, remainder 0);
create table public.aro169_partitioned_binding_refs_p1
  partition of public.aro169_partitioned_binding_refs
  for values with (modulus 2, remainder 1);
alter table public.aro169_partitioned_binding_refs
  add constraint aro169_partitioned_binding_fk
  foreign key (node_id, environment, credential_version)
  references symphony_staging.node_bindings(
    node_id, environment, credential_version
  )
  match simple
  on update cascade
  on delete restrict
  deferrable initially immediate;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted a partitioned external foreign key" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "drop table public.aro169_partitioned_binding_refs;" >/dev/null

for publication_kind in all_tables staging_schema explicit_relation; do
  case "$publication_kind" in
    all_tables)
      psql_admin -c "
        create publication aro169_publication_drift for all tables;
      " >/dev/null
      ;;
    staging_schema)
      psql_admin -c "
        create publication aro169_publication_drift
          for tables in schema symphony_staging;
      " >/dev/null
      ;;
    explicit_relation)
      psql_admin -c "
        create publication aro169_publication_drift
          for table symphony_staging.nodes;
      " >/dev/null
      ;;
  esac
  if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
    >/dev/null 2>&1; then
    echo "v3 apply unexpectedly accepted $publication_kind publication drift" >&2
    exit 1
  fi
  test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
  psql_admin -c "drop publication aro169_publication_drift;" >/dev/null
done

psql_admin -c "
  alter table symphony_staging.nodes
    alter column display_alias type text collate pg_catalog.\"C\";
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted column collation drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  alter table symphony_staging.nodes
    alter column display_alias type text collate pg_catalog.\"default\";
  update pg_index
  set indcollation = array['pg_catalog.\"C\"'::regcollation]::oidvector
  where indexrelid =
    'symphony_staging.routing_assignments_pkey'::regclass;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted index collation drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  update pg_index
  set indcollation = array['pg_catalog.\"default\"'::regcollation]::oidvector
  where indexrelid =
    'symphony_staging.routing_assignments_pkey'::regclass;
" >/dev/null

psql_admin -c "drop extension pgcrypto;" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted missing pgcrypto" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "create extension pgcrypto with schema extensions;" >/dev/null
set_pgcrypto_live_acl

psql_admin -c "alter extension pgcrypto set schema public;" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto in the wrong schema" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "alter extension pgcrypto set schema extensions;" >/dev/null

psql_admin -c "
  alter function extensions.digest(text, text) owner to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto owner drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  alter function extensions.digest(text, text) owner to postgres;
" >/dev/null
set_pgcrypto_live_acl

psql_admin -c "
  revoke execute on function extensions.digest(text, text) from public;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto ACL drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  update pg_proc
  set proacl = null
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
set_pgcrypto_live_acl

psql_admin -c "
  update pg_proc
  set proacl = null
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted default pgcrypto ACL state" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"

psql_admin -c "
  update pg_proc
  set proacl = '{}'::aclitem[]
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted explicit-empty pgcrypto ACL state" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  update pg_proc
  set proacl = null
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
set_pgcrypto_live_acl

psql_admin -c "
  grant execute on function extensions.digest(text, text) to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted an extra pgcrypto ACL grant" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  revoke execute on function extensions.digest(text, text) from service_role;
" >/dev/null

psql_admin -c "
  revoke execute on function extensions.digest(text, text) from dashboard_user;
  grant execute on function extensions.digest(text, text) to authenticated;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto grantee drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  revoke execute on function extensions.digest(text, text) from authenticated;
" >/dev/null
set_pgcrypto_live_acl

psql_admin -c "
  revoke grant option for execute on function extensions.digest(text, text)
    from postgres;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto grant-option drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
set_pgcrypto_live_acl

psql_admin <<'SQL'
create role "aro169>pgcrypto,角色\grantor" nologin;
grant usage on schema extensions to "aro169>pgcrypto,角色\grantor";
grant execute on function extensions.digest(text, text)
  to "aro169>pgcrypto,角色\grantor" with grant option;
set role "aro169>pgcrypto,角色\grantor";
grant execute on function extensions.digest(text, text) to authenticated;
reset role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto grantor/special-role drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin <<'SQL'
set role "aro169>pgcrypto,角色\grantor";
revoke execute on function extensions.digest(text, text) from authenticated;
reset role;
revoke execute on function extensions.digest(text, text)
  from "aro169>pgcrypto,角色\grantor";
revoke usage on schema extensions from "aro169>pgcrypto,角色\grantor";
drop role "aro169>pgcrypto,角色\grantor";
SQL
set_pgcrypto_live_acl

psql_admin -c "
  create or replace function extensions.digest(text, text)
  returns bytea
  language sql
  immutable strict parallel safe
  as 'select decode(md5(\$1 || \$2), ''hex'')';
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted pgcrypto function identity drift" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  drop extension pgcrypto;
  create extension pgcrypto with schema extensions;
" >/dev/null
set_pgcrypto_live_acl

psql_admin <<'SQL'
create role aro169_v2_drift_writer nologin noinherit;
grant update on symphony_staging.nodes to aro169_v2_drift_writer;
grant aro169_v2_drift_writer to symphony_staging_provisioner
  with inherit true, set false;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted v2 authorization state" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin <<'SQL'
revoke aro169_v2_drift_writer from symphony_staging_provisioner;
revoke update on symphony_staging.nodes from aro169_v2_drift_writer;
drop role aro169_v2_drift_writer;
SQL

psql_admin -c "
  revoke select (node_id) on symphony_staging.nodes
    from symphony_staging_runtime;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted v2 column ACL drift" >&2
  exit 1
fi
psql_admin -c "
  grant select (node_id) on symphony_staging.nodes
    to symphony_staging_runtime;
" >/dev/null

psql_admin -c "
  grant select on symphony_staging.nodes to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unrelated-role ACL drift" >&2
  exit 1
fi
psql_admin -c "
  revoke select on symphony_staging.nodes from service_role;
" >/dev/null

psql_admin -c "
  alter default privileges in schema symphony_staging
    grant select on tables to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted default ACL drift" >&2
  exit 1
fi
psql_admin -c "
  alter default privileges in schema symphony_staging
    revoke select on tables from service_role;
" >/dev/null

psql_admin <<'SQL'
create role aro169_unlisted_role nologin;
alter default privileges in schema symphony_staging
  grant select on tables to aro169_unlisted_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unlisted-role default ACL drift" >&2
  exit 1
fi
psql_admin <<'SQL'
alter default privileges in schema symphony_staging
  revoke select on tables from aro169_unlisted_role;
grant usage on schema symphony_staging to aro169_unlisted_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unlisted schema ACL drift" >&2
  exit 1
fi
psql_admin <<'SQL'
revoke usage on schema symphony_staging from aro169_unlisted_role;
alter table symphony_staging.nodes disable trigger enforce_node_transition;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted disabled foundation trigger" >&2
  exit 1
fi
psql_admin <<'SQL'
alter table symphony_staging.nodes enable trigger enforce_node_transition;
create function public.enforce_node_transition()
returns trigger language plpgsql
as $$ begin return new; end $$;
drop trigger enforce_node_transition on symphony_staging.nodes;
create trigger enforce_node_transition
before update on symphony_staging.nodes
for each row execute function public.enforce_node_transition();
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted trigger function namespace" >&2
  exit 1
fi
psql_admin <<'SQL'
drop trigger enforce_node_transition on symphony_staging.nodes;
create trigger enforce_node_transition
before update on symphony_staging.nodes
for each row execute function symphony_staging.enforce_node_transition();
drop function public.enforce_node_transition();
drop index symphony_staging.routing_assignments_target_node_id_idx;
create index routing_assignments_target_node_id_idx
  on symphony_staging.routing_assignments using hash (target_node_id);
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted index access method" >&2
  exit 1
fi
psql_admin <<'SQL'
drop index symphony_staging.routing_assignments_target_node_id_idx;
create index routing_assignments_target_node_id_idx
  on symphony_staging.routing_assignments (target_node_id);
alter table symphony_staging.routing_assignments
  drop constraint routing_assignments_routing_revision_check;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted foundation constraint" >&2
  exit 1
fi
psql_admin <<'SQL'
alter table symphony_staging.routing_assignments
  add constraint routing_assignments_routing_revision_check
  check (routing_revision > 0);
alter table symphony_staging.nodes
  alter column credential_version set default 2;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted drifted foundation column default" >&2
  exit 1
fi
psql_admin <<'SQL'
alter table symphony_staging.nodes
  alter column credential_version set default 1;
create table symphony_staging.aro169_unexpected_v2_object(id integer);
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted extra staging object" >&2
  exit 1
fi
psql_admin <<'SQL'
drop table symphony_staging.aro169_unexpected_v2_object;
drop role aro169_unlisted_role;
SQL

psql_admin -c "
  insert into symphony_staging.nodes(node_id, status)
  values ('16900000-0000-4000-8000-000000000099', 'active');
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted nonempty v2 foundation data" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select to_regclass('symphony_staging.node_login_principals') is null;")" = "t"
psql_admin -c "
  delete from symphony_staging.nodes
  where node_id = '16900000-0000-4000-8000-000000000099';
  insert into symphony_staging.contract_versions(
    contract_name, contract_version, migration_name
  ) values ('aro169-unexpected-contract', 1, 'test');
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted an extra v2 contract row" >&2
  exit 1
fi
psql_admin -c "
  delete from symphony_staging.contract_versions
  where contract_name = 'aro169-unexpected-contract';
  alter table symphony_staging.node_bindings disable trigger all;
  alter table symphony_staging.node_bindings
    enable trigger enforce_node_binding_transition;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted disabled internal FK triggers" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.node_bindings enable trigger all;
  alter table symphony_staging.foundation_audit_events set unlogged;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted unlogged foundation audit data" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.foundation_audit_events set logged;
  alter table symphony_staging.nodes
    replica identity using index nodes_pkey;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted replica identity drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.nodes replica identity default;
  create rule aro169_nodes_noop as
    on insert to symphony_staging.nodes do instead nothing;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted rewrite-rule drift" >&2
  exit 1
fi
psql_admin -c "
  drop rule aro169_nodes_noop on symphony_staging.nodes;
  create type symphony_production.aro169_unexpected_type as enum ('drift');
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql" \
  >/dev/null 2>&1; then
  echo "v3 apply unexpectedly accepted production auxiliary objects" >&2
  exit 1
fi
psql_admin -c "
  drop type symphony_production.aro169_unexpected_type;
" >/dev/null

psql_root <<'SQL'
update pg_proc procedure
set proacl = (
  select array_agg(acl_item order by ordinal desc) as proacl
  from unnest(procedure.proacl) with ordinality reordered_acl(acl_item, ordinal)
)
where procedure.oid in (
  'extensions.gen_random_bytes(integer)'::regprocedure,
  'extensions.digest(text,text)'::regprocedure,
  'extensions.set_graphql_placeholder()'::regprocedure,
  'extensions.grant_pg_cron_access()'::regprocedure,
  'extensions.grant_pg_graphql_access()'::regprocedure,
  'extensions.grant_pg_net_access()'::regprocedure,
  'extensions.pgrst_ddl_watch()'::regprocedure,
  'extensions.pgrst_drop_watch()'::regprocedure
);

create function public.pgrst_drop_watch()
returns event_trigger
language plpgsql
as 'begin null; end';
create table public.pg_proc (shadow text);
create table public.pg_namespace (shadow text);
create table public.pg_language (shadow text);
SQL

psql_root <<'SQL'
set role supabase_admin;
grant symphony_staging_runtime, symphony_staging_provisioner to postgres
  with admin option, inherit false, set false;
reset role;
alter role postgres
  nosuperuser createrole createdb replication bypassrls;
SQL

test "$(psql_admin -A -t -c "select current_setting('is_superuser');")" = "off"
if psql_admin -c "
  begin;
  lock table pg_catalog.pg_proc in share mode;
" >/dev/null 2>&1; then
  echo "hosted-like migration role unexpectedly locked pg_catalog.pg_proc" >&2
  exit 1
fi

PGOPTIONS="-c search_path=public,extensions,pg_catalog" \
  psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

psql_admin -c "drop function public.pgrst_drop_watch();" >/dev/null

psql_root <<'SQL'
update pg_namespace namespace
set nspacl = (
  select array_agg(acl_item order by ordinal desc)
  from unnest(namespace.nspacl) with ordinality reordered_acl(acl_item, ordinal)
)
where namespace.nspname in ('symphony_staging', 'symphony_production')
  and pg_catalog.cardinality(namespace.nspacl) > 1;

update pg_default_acl default_acl
set defaclacl = (
  select array_agg(acl_item order by ordinal desc)
  from unnest(default_acl.defaclacl) with ordinality
    reordered_acl(acl_item, ordinal)
)
where pg_catalog.cardinality(default_acl.defaclacl) > 1
  and pg_get_userbyid(default_acl.defaclrole) = 'postgres'
  and (
    default_acl.defaclnamespace = 0
    or default_acl.defaclnamespace in (
      'symphony_staging'::regnamespace,
      'symphony_production'::regnamespace
    )
  );
SQL

provisioned="$(
  psql_admin -A -t -F '|' -c \
    "set password_encryption = 'md5';
    select * from symphony_staging.provision_node(
      '16900000-0000-4000-8000-000000000001',
      'disposable-node',
      'ARO-169-disposable',
      'exclusive'
    );"
)"
IFS='|' read -r node_id _binding_id login_role node_credential contract_version credential_returned \
  <<<"$provisioned"
unset provisioned

test "$contract_version" = "3"
test "$credential_returned" = "t"
test -n "$node_id"
test -n "$login_role"
test -n "$node_credential"
test "$(psql_root -A -t -c "select rolpassword like 'SCRAM-SHA-256\\$%' from pg_authid where rolname = '$login_role';")" = "t"
test "$(psql_admin -A -t -c "select target_node_id = '$node_id' and routing_policy = 'exclusive' from symphony_staging.routing_assignments where issue_id = 'ARO-169-disposable';")" = "t"

replayed="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.provision_node(
      '16900000-0000-4000-8000-000000000001',
      'disposable-node',
      'ARO-169-disposable',
      'exclusive'
    );"
)"
IFS='|' read -r replayed_node_id _ _ replayed_credential _ replayed_secret \
  <<<"$replayed"
unset replayed
test "$replayed_node_id" = "$node_id"
test -z "$replayed_credential"
test "$replayed_secret" = "f"

if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000001',
  'different-request',
  'ARO-169-disposable',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "operation ID unexpectedly accepted a different request" >&2
  exit 1
fi

psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000004',
  E'fingerprint-a\\nfingerprint-b',
  'fingerprint-c',
  'exclusive'
);" >/dev/null
if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000004',
  'fingerprint-a',
  E'fingerprint-b\\nfingerprint-c',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "structured operation fingerprint accepted a newline-boundary collision" >&2
  exit 1
fi
psql_admin <<'SQL'
select node_id as node_id
from symphony_staging.node_lifecycle_operations
where operation_id = '16900000-0000-4000-8000-000000000004'
\gset collision_
select format(
  'revoke execute on function symphony_staging.authenticate_node(uuid, uuid) from %I',
  login_role
)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
select format('revoke usage on schema symphony_staging from %I', login_role)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
select format('drop role %I', login_role)
from symphony_staging.node_principal_history
where node_id = :'collision_node_id'
\gexec
delete from symphony_staging.foundation_audit_events
where node_id = :'collision_node_id';
delete from symphony_staging.routing_assignments
where issue_id = E'fingerprint-c';
delete from symphony_staging.node_lifecycle_operations
where operation_id = '16900000-0000-4000-8000-000000000004';
delete from symphony_staging.node_bindings
where node_id = :'collision_node_id';
delete from symphony_staging.node_login_principals
where node_id = :'collision_node_id';
delete from symphony_staging.node_principal_history
where node_id = :'collision_node_id';
delete from symphony_staging.nodes
where node_id = :'collision_node_id';
SQL

for _attempt in 1 2; do
  psql_admin -c "select * from symphony_staging.provision_node(
    '16900000-0000-4000-8000-000000000002',
    'concurrent-node',
    'ARO-169-concurrent',
    'exclusive'
  );" >/dev/null &
done
wait
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_lifecycle_operations where operation_id = '16900000-0000-4000-8000-000000000002';")" = "1"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.routing_assignments where issue_id = 'ARO-169-concurrent';")" = "1"

if psql_admin -c "select * from symphony_staging.provision_node(
  '16900000-0000-4000-8000-000000000003',
  'routing-conflict',
  'ARO-169-disposable',
  'exclusive'
);" >/dev/null 2>&1; then
  echo "routing conflict unexpectedly provisioned a partial node" >&2
  exit 1
fi
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_lifecycle_operations where operation_id = '16900000-0000-4000-8000-000000000003';")" = "0"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.nodes where display_alias = 'routing-conflict';")" = "0"

node_url="postgresql://${login_role}@localhost:5432/postgres"
instance_one="00000000-0000-4000-8000-000000000169"
instance_two="00000000-0000-4000-8000-000000000269"
instance_three="00000000-0000-4000-8000-000000000369"
instance_four="00000000-0000-4000-8000-000000000469"
instance_five="00000000-0000-4000-8000-000000000569"
instance_six="00000000-0000-4000-8000-000000000669"

if PGPASSWORD=wrong psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "wrong credential unexpectedly authenticated" >&2
  exit 1
fi

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_production.forbidden;" \
  >/dev/null 2>&1; then
  echo "node role unexpectedly accessed production" >&2
  exit 1
fi

if PGPASSWORD="$node_credential" \
  psql -X -q -d "$node_url" \
  -c "set role symphony_staging_runtime; select * from symphony_staging.nodes;" \
  >/dev/null 2>&1; then
  echo "node login unexpectedly bypassed authentication with SET ROLE" >&2
  exit 1
fi

psql_admin <<SQL
create function symphony_staging.test_delay_authentication()
returns trigger
language plpgsql
as \$\$
begin
  if new.node_instance_id = '$instance_three' then
    perform pg_sleep(4);
  end if;
  return new;
end
\$\$;
create trigger test_delay_authentication
before insert on symphony_staging.node_instance_history
for each row execute function symphony_staging.test_delay_authentication();
SQL

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_one');" \
  -c "select pg_advisory_unlock_all();" \
  -c "select pg_sleep(8);" \
  >/dev/null &
first_session_pid=$!
sleep 2

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null 2>&1; then
  echo "duplicate node session unexpectedly authenticated" >&2
  kill "$first_session_pid" 2>/dev/null || true
  exit 1
fi

wait "$first_session_pid"

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null 2>&1; then
  echo "disconnected backend implicitly retired its instance" >&2
  exit 1
fi

psql_admin <<'SQL'
create role aro169_disposable_inherit_only nologin inherit;
grant symphony_staging_provisioner to aro169_disposable_inherit_only
  with inherit true, set false;
SQL
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000104',
    '$node_id',
    '$instance_one'
  );
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed SET capability" >&2
  exit 1
fi
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  update symphony_staging.node_login_principals
  set revoked_at = clock_timestamp()
  where node_id = '$node_id';
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed lifecycle table boundary" >&2
  exit 1
fi
if psql_admin -c "
  set session authorization aro169_disposable_inherit_only;
  update symphony_staging.nodes
  set credential_version = credential_version + 1
  where node_id = '$node_id';
" >/dev/null 2>&1; then
  echo "inherit-only provisioner member bypassed foundation table boundary" >&2
  exit 1
fi
psql_admin <<'SQL'
revoke symphony_staging_provisioner from aro169_disposable_inherit_only;
drop role aro169_disposable_inherit_only;
SQL

psql_admin <<SQL
create role aro169_disposable_bootstrap nologin noinherit;
grant symphony_staging_provisioner to aro169_disposable_bootstrap
  with inherit false, set true;
set session authorization aro169_disposable_bootstrap;
set role symphony_staging_provisioner;
select * from symphony_staging.retire_node_instance(
  '16900000-0000-4000-8000-000000000101',
  '$node_id',
  '$instance_one'
);
reset session authorization;
drop role aro169_disposable_bootstrap;
SQL
psql_admin -c \
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000101',
    '$node_id',
    '$instance_one'
  );" >/dev/null

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_two');" \
  >/dev/null

if PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_one');" \
  >/dev/null 2>&1; then
  echo "old node instance unexpectedly authenticated again" >&2
  exit 1
fi

psql_admin -c \
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000102',
    '$node_id',
    '$instance_two'
  );" \
  >/dev/null

if PGPASSWORD="$node_credential" \
  psql -X -q -d "postgresql://${login_role}@localhost:1/postgres" \
  -c "select 1" >/dev/null 2>&1; then
  echo "unreachable registry unexpectedly connected" >&2
  exit 1
fi

PGPASSWORD="$node_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_three');" \
  -c "select pg_sleep(8);" \
  -c "alter role current_user password 'disposable-old-session-choice';" \
  >/dev/null &
pre_rotation_session_pid=$!
sleep 2

rotation_started_at="$(date +%s)"
rotated="$(
  psql_admin -A -t -F '|' -c \
    "set password_encryption = 'md5';
    select * from symphony_staging.rotate_node_credential(
      '16900000-0000-4000-8000-000000000201',
      '$node_id'
    );"
)"
rotation_elapsed="$(( $(date +%s) - rotation_started_at ))"
if [ "$rotation_elapsed" -lt 2 ]; then
  echo "rotation did not serialize with in-flight authentication" >&2
  exit 1
fi
psql_admin <<'SQL'
drop trigger test_delay_authentication
  on symphony_staging.node_instance_history;
drop function symphony_staging.test_delay_authentication();
SQL
IFS='|' read -r _rotated_node_id _rotated_role rotated_credential \
  credential_version rotated_contract_version rotated_secret <<<"$rotated"
unset rotated

test "$credential_version" = "2"
test "$rotated_contract_version" = "3"
test "$rotated_secret" = "t"
test "$_rotated_role" != "$login_role"
test "$(psql_root -A -t -c "select rolpassword like 'SCRAM-SHA-256\\$%' from pg_authid where rolname = '$_rotated_role';")" = "t"
rotated_node_url="postgresql://${_rotated_role}@localhost:5432/postgres"

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$rotated_node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_four');" \
  >/dev/null

wait "$pre_rotation_session_pid"

if PGPASSWORD="$node_credential" \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "rotated credential remained valid" >&2
  exit 1
fi

if PGPASSWORD=disposable-old-session-choice \
  psql -X -q -d "$node_url" -c "select 1" >/dev/null 2>&1; then
  echo "retired login role reconnected after choosing its own password" >&2
  exit 1
fi
unset node_credential

psql_admin -c \
  "select * from symphony_staging.retire_node_instance(
    '16900000-0000-4000-8000-000000000103',
    '$node_id',
    '$instance_four'
  );" \
  >/dev/null

PGPASSWORD="$rotated_credential" \
  psql -X -q -v ON_ERROR_STOP=1 -d "$rotated_node_url" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_five');" \
  -c "select pg_sleep(4);" \
  -c "select * from symphony_staging.authenticate_node('$node_id', '$instance_six');" \
  >/dev/null 2>&1 &
open_session_pid=$!
sleep 1

psql_admin -c "select * from symphony_staging.revoke_node(
  '16900000-0000-4000-8000-000000000301',
  '$node_id'
);" >/dev/null

if wait "$open_session_pid"; then
  echo "open session retained authentication after durable revocation" >&2
  exit 1
fi

if PGPASSWORD="$rotated_credential" \
  psql -X -q -d "$rotated_node_url" -c "select 1" >/dev/null 2>&1; then
  echo "revoked credential remained valid" >&2
  exit 1
fi
unset rotated_credential

reenrolled="$(
  psql_admin -A -t -F '|' -c \
    "set password_encryption = 'md5';
    select * from symphony_staging.reenroll_node(
      '16900000-0000-4000-8000-000000000401',
      '$node_id'
    );"
)"
IFS='|' read -r _reenrolled_node_id reenrolled_role reenrolled_credential \
  reenrolled_version reenrolled_contract reenrolled_secret <<<"$reenrolled"
unset reenrolled
test "$_reenrolled_node_id" = "$node_id"
test "$reenrolled_version" = "3"
test "$reenrolled_contract" = "3"
test "$reenrolled_secret" = "t"
test "$(psql_root -A -t -c "select rolpassword like 'SCRAM-SHA-256\\$%' from pg_authid where rolname = '$reenrolled_role';")" = "t"
test "$(psql_admin -A -t -c "select count(*) from symphony_staging.node_principal_history where node_id = '$node_id';")" = "3"

reenroll_replay="$(
  psql_admin -A -t -F '|' -c \
    "select * from symphony_staging.reenroll_node(
      '16900000-0000-4000-8000-000000000401',
      '$node_id'
    );"
)"
IFS='|' read -r _ _ replayed_reenroll_credential _ _ replayed_reenroll_secret \
  <<<"$reenroll_replay"
unset reenroll_replay
test -z "$replayed_reenroll_credential"
test "$replayed_reenroll_secret" = "f"
unset reenrolled_credential

if psql_admin -f \
  "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly orphaned a provisioned principal" >&2
  exit 1
fi

psql_admin <<SQL
select format(
  'revoke execute on function symphony_staging.authenticate_node(uuid, uuid) from %I',
  login_role
)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
select format('revoke usage on schema symphony_staging from %I', login_role)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
select format('drop role %I', login_role)
from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
)
\gexec
delete from symphony_staging.foundation_audit_events
where node_id = (
  select node_id from symphony_staging.node_lifecycle_operations
  where operation_id = '16900000-0000-4000-8000-000000000002'
);
delete from symphony_staging.routing_assignments where issue_id = 'ARO-169-concurrent';
delete from symphony_staging.node_principal_history
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_login_principals
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_lifecycle_operations
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.node_bindings
where node_id = (
  select node_id from symphony_staging.nodes
  where display_alias = 'concurrent-node'
);
delete from symphony_staging.nodes where display_alias = 'concurrent-node';

revoke execute on function symphony_staging.authenticate_node(uuid, uuid)
  from "$reenrolled_role";
revoke usage on schema symphony_staging from "$reenrolled_role";
delete from symphony_staging.foundation_audit_events where node_id = '$node_id';
delete from symphony_staging.active_node_instances where node_id = '$node_id';
delete from symphony_staging.node_instance_history where node_id = '$node_id';
delete from symphony_staging.routing_assignments where target_node_id = '$node_id';
delete from symphony_staging.node_lifecycle_operations where node_id = '$node_id';
delete from symphony_staging.node_bindings where node_id = '$node_id';
delete from symphony_staging.node_login_principals where node_id = '$node_id';
delete from symphony_staging.node_principal_history where node_id = '$node_id';
delete from symphony_staging.nodes where node_id = '$node_id';
drop role "$login_role";
drop role "$_rotated_role";
drop role "$reenrolled_role";
SQL

psql_admin -c "
  update symphony_staging.contract_versions
  set contract_version = 4, migration_name = 'future-contract'
  where contract_name = 'node-identity-routing-foundation';
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted a future contract" >&2
  exit 1
fi
psql_admin -c "
  update symphony_staging.contract_versions
  set contract_version = 3,
      migration_name = '20260724010000_aro_169_node_enrollment'
  where contract_name = 'node-identity-routing-foundation';
" >/dev/null

psql_admin -c "alter table symphony_staging.active_node_instances rename to drifted_active_node_instances;" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted object drift" >&2
  exit 1
fi
psql_admin -c "alter table symphony_staging.drifted_active_node_instances rename to active_node_instances;" >/dev/null

psql_admin -c "
  create publication aro169_rollback_publication
    for table symphony_staging.active_node_instances;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted publication drift" >&2
  exit 1
fi
psql_admin -c "drop publication aro169_rollback_publication;" >/dev/null

psql_root <<'SQL'
create function public.aro169_rollback_event_drift()
returns event_trigger
language plpgsql
as $$ begin null; end $$;
create event trigger aro169_rollback_event_drift
  on ddl_command_end
  execute function public.aro169_rollback_event_drift();
alter event trigger aro169_rollback_event_drift disable;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted event-trigger drift" >&2
  exit 1
fi
psql_root <<'SQL'
drop event trigger aro169_rollback_event_drift;
drop function public.aro169_rollback_event_drift();
SQL

psql_root -c "
  alter function extensions.digest(text, text) owner to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted pgcrypto dependency drift" >&2
  exit 1
fi
psql_root -c "
  alter function extensions.digest(text, text) owner to postgres;
" >/dev/null

psql_admin -c "
  revoke execute on function extensions.digest(text, text) from dashboard_user;
  grant execute on function extensions.digest(text, text) to authenticated;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted pgcrypto ACL grantee drift" >&2
  exit 1
fi
psql_admin -c "
  revoke execute on function extensions.digest(text, text) from authenticated;
" >/dev/null
set_pgcrypto_live_acl

psql_root -c "
  update pg_proc
  set proacl = '{}'::aclitem[]
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly treated an explicit empty ACL as the default ACL" >&2
  exit 1
fi
psql_root -c "
  update pg_proc
  set proacl = null
  where oid = 'extensions.digest(text,text)'::regprocedure;
" >/dev/null
set_pgcrypto_live_acl

psql_root -c "
  update pg_proc
  set proacl = null
  where oid = 'symphony_staging.enforce_node_transition()'::regprocedure;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted default trigger-function ACL drift" >&2
  exit 1
fi
psql_root -c "
  update pg_proc
  set proacl = '{}'::aclitem[]
  where oid = 'symphony_staging.enforce_node_transition()'::regprocedure;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted explicit-empty trigger-function ACL drift" >&2
  exit 1
fi
psql_root -c "
  update pg_proc procedure
  set proacl = array[
    pg_catalog.format(
      '%s=X/%s',
      pg_get_userbyid(procedure.proowner),
      pg_get_userbyid(procedure.proowner)
    )::aclitem
  ]
  where oid = 'symphony_staging.enforce_node_transition()'::regprocedure;
" >/dev/null

psql_admin -c "
  alter table symphony_staging.node_lifecycle_operations
    alter column operation_type type text collate pg_catalog.\"C\";
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted column collation drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.node_lifecycle_operations
    alter column operation_type type text collate pg_catalog.\"default\";
" >/dev/null

psql_admin -c "
  create index aro169_drifted_active_instance_authenticated_at_idx
  on symphony_staging.active_node_instances (authenticated_at);
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted index drift" >&2
  exit 1
fi
psql_admin -c "
  drop index symphony_staging.aro169_drifted_active_instance_authenticated_at_idx;
" >/dev/null

if psql_admin \
  -c "begin; grant select on symphony_staging.active_node_instances to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted ACL drift" >&2
  exit 1
fi
if psql_admin \
  -c "begin; grant select (node_id) on symphony_staging.node_login_principals to service_role;" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted column ACL drift" >&2
  exit 1
fi
if psql_admin \
  -c "begin;
      create function symphony_staging.aro169_drift_trigger()
      returns trigger language plpgsql
      set search_path = pg_catalog
      as \$\$ begin return new; end \$\$;
      create trigger aro169_drift_trigger
      before update on symphony_staging.nodes
      for each row execute function symphony_staging.aro169_drift_trigger();" \
  -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted trigger drift" >&2
  exit 1
fi
psql_admin -c "
  grant symphony_staging_provisioner to service_role
    with inherit false, set true;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted membership drift" >&2
  exit 1
fi
psql_admin -c "
  revoke symphony_staging_provisioner from service_role;
" >/dev/null

psql_admin -c "
  alter sequence symphony_staging.foundation_audit_events_audit_id_seq
    increment by 2 cache 3 cycle;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted sequence drift" >&2
  exit 1
fi
psql_admin -c "
  alter sequence symphony_staging.foundation_audit_events_audit_id_seq
    increment by 1 cache 1 no cycle;
" >/dev/null

psql_admin -c "
  alter role symphony_staging_provisioner login;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted managed-role attribute drift" >&2
  exit 1
fi
psql_admin -c "
  alter role symphony_staging_provisioner nologin;
" >/dev/null

psql_admin -c "
  alter role symphony_staging_provisioner in database postgres
    set statement_timeout = '1ms';
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted database-scoped managed-role settings" >&2
  exit 1
fi
psql_admin -c "
  alter role symphony_staging_provisioner in database postgres
    reset statement_timeout;
" >/dev/null

psql_admin <<'SQL'
create view public.aro169_external_nodes
with (security_invoker = false)
as select node_id, display_alias from symphony_staging.nodes;
grant select on public.aro169_external_nodes to service_role;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted an external dependent view" >&2
  exit 1
fi
psql_admin <<'SQL'
revoke select on public.aro169_external_nodes from service_role;
drop view public.aro169_external_nodes;
SQL

psql_admin <<'SQL'
create table public.aro169_external_principal_refs (
  node_id uuid,
  constraint aro169_external_principal_fk
    foreign key (node_id)
    references symphony_staging.node_login_principals(node_id)
    on update cascade
    on delete restrict
    deferrable initially immediate
    not valid
);
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted a cross-schema foreign key" >&2
  exit 1
fi
psql_admin -c "drop table public.aro169_external_principal_refs;" >/dev/null

psql_admin <<'SQL'
create table public.aro169_partitioned_principal_refs (
  node_id uuid not null
) partition by hash (node_id);
create table public.aro169_partitioned_principal_refs_p0
  partition of public.aro169_partitioned_principal_refs
  for values with (modulus 2, remainder 0);
create table public.aro169_partitioned_principal_refs_p1
  partition of public.aro169_partitioned_principal_refs
  for values with (modulus 2, remainder 1);
alter table public.aro169_partitioned_principal_refs
  add constraint aro169_partitioned_principal_fk
  foreign key (node_id)
  references symphony_staging.node_login_principals(node_id)
  match simple
  on update restrict
  on delete cascade
  deferrable initially deferred;
SQL
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted a partitioned external foreign key" >&2
  exit 1
fi
psql_admin -c "drop table public.aro169_partitioned_principal_refs;" >/dev/null

psql_admin -c "
  grant create on schema symphony_staging to service_role;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted schema ACL drift" >&2
  exit 1
fi
psql_admin -c "
  revoke create on schema symphony_staging from service_role;
" >/dev/null

psql_admin -c "
  alter table symphony_staging.nodes force row level security;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted FORCE RLS drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.nodes no force row level security;
" >/dev/null

psql_admin -c "
  create table symphony_staging.aro169_unexpected_v3_object(id integer);
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted extra staging object" >&2
  exit 1
fi
psql_admin -c "
  drop table symphony_staging.aro169_unexpected_v3_object;
" >/dev/null

psql_admin -c "
  create text search dictionary symphony_staging.aro169_drift_dictionary
    (template = pg_catalog.simple);
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted auxiliary catalog object drift" >&2
  exit 1
fi
psql_admin -c "
  drop text search dictionary symphony_staging.aro169_drift_dictionary;
" >/dev/null

psql_admin -c "
  alter table symphony_staging.foundation_audit_events
    alter column audit_id set generated by default;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted identity-mode drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.foundation_audit_events
    alter column audit_id set generated always;
  create rule aro169_nodes_noop as
    on insert to symphony_staging.nodes do instead nothing;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted rewrite-rule drift" >&2
  exit 1
fi
psql_admin -c "
  drop rule aro169_nodes_noop on symphony_staging.nodes;
  alter table symphony_staging.node_bindings disable trigger all;
  alter table symphony_staging.node_bindings
    enable trigger enforce_node_binding_transition;
" >/dev/null
if psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql" \
  >/dev/null 2>&1; then
  echo "rollback unexpectedly accepted internal-trigger drift" >&2
  exit 1
fi
psql_admin -c "
  alter table symphony_staging.node_bindings enable trigger all;
" >/dev/null

psql_admin -c "
  select pg_advisory_lock(
    hashtextextended('aroak:symphony_staging:migrations', 0)
  );
  select pg_sleep(4);
" >/dev/null &
migration_lock_pid=$!
sleep 1
managed_identity_default="$(
  psql_admin -A -t -c "
    select format(
      '%I.%I(%s)',
      namespace.nspname,
      procedure.proname,
      pg_get_function_identity_arguments(procedure.oid)
    )
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where procedure.oid = 'extensions.pgrst_drop_watch()'::regprocedure;
  "
)"
managed_identity_extensions_path="$(
  psql_admin -A -t \
    -c "set search_path = extensions, public;" \
    -c "
      select format(
        '%I.%I(%s)',
        namespace.nspname,
        procedure.proname,
        pg_get_function_identity_arguments(procedure.oid)
      )
      from pg_proc procedure
      join pg_namespace namespace on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'extensions'
        and procedure.proname = 'pgrst_drop_watch'
        and procedure.pronargs = 0;
    "
)"
test "$managed_identity_default" = "$managed_identity_extensions_path"
test "$managed_identity_default" = "extensions.pgrst_drop_watch()"
rollback_started_at="$(date +%s)"
PGOPTIONS="-c search_path=public,extensions,pg_catalog" \
  psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.down.sql"
rollback_elapsed="$(( $(date +%s) - rollback_started_at ))"
wait "$migration_lock_pid"
if [ "$rollback_elapsed" -lt 2 ]; then
  echo "rollback did not serialize with concurrent contract DDL" >&2
  exit 1
fi

test "$(psql_admin -A -t -c "select contract_version from symphony_staging.contract_versions where contract_name = 'node-identity-routing-foundation';")" = "2"
test "$(psql_admin -A -t -c "select has_table_privilege('symphony_staging_provisioner', 'symphony_staging.nodes', 'SELECT,INSERT,UPDATE');")" = "t"
test "$(psql_admin -A -t -c "select count(*) from pg_policies where schemaname = 'symphony_staging' and policyname in ('provisioner_manage_nodes', 'provisioner_manage_node_bindings', 'provisioner_manage_routing_assignments') and roles = array['symphony_staging_provisioner']::name[];")" = "3"
PGOPTIONS="-c search_path=public,extensions,pg_catalog" \
  psql_admin -f "$migrations_dir/20260724010000_aro_169_node_enrollment.sql"

echo "ARO-169 disposable PostgreSQL lifecycle passed without printing credentials"
