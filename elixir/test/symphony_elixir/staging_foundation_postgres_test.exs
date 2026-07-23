defmodule SymphonyElixir.StagingFoundationPostgresTest do
  use ExUnit.Case, async: false

  @migration Path.expand(
               "../../priv/symphony_migrations/20260723000000_aro_163_staging_foundation.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260723000000_aro_163_staging_foundation.down.sql",
              __DIR__
            )

  @database_url System.get_env("ARO163_MIGRATION_TEST_DATABASE_URL")
  @psql System.find_executable("psql")
  @enabled @database_url not in [nil, ""] and @psql != nil and
             System.get_env("ARO163_ALLOW_DESTRUCTIVE_DB_TEST") == "1"

  @moduletag skip:
               if(@enabled,
                 do: false,
                 else:
                   "set ARO163_MIGRATION_TEST_DATABASE_URL and " <>
                     "ARO163_ALLOW_DESTRUCTIVE_DB_TEST=1 with psql on PATH"
               )

  setup do
    on_exit(fn ->
      run_sql("""
      drop schema if exists symphony_staging cascade;
      drop table if exists public.aro_163_acl_sentinel;
      drop role if exists aro_163_acl_reader;
      drop role if exists symphony_staging_runtime;
      drop role if exists symphony_staging_provisioner;
      """)
    end)

    :ok
  end

  test "apply and rollback preserve shared ACLs and SET ROLE uses transaction-local search path" do
    run_sql("""
    create schema symphony_staging;
    create role aro_163_acl_reader nologin;
    create table public.aro_163_acl_sentinel (id integer primary key);
    grant select on public.aro_163_acl_sentinel to aro_163_acl_reader;
    create temporary table aro_163_acl_before as
    select
      (select nspacl from pg_namespace where nspname = 'symphony_staging') as schema_acl,
      (select relacl from pg_class where oid = 'public.aro_163_acl_sentinel'::regclass) as table_acl,
      (select coalesce(jsonb_agg(to_jsonb(defaults) order by defaults.oid), '[]'::jsonb)
       from pg_default_acl defaults) as default_acls;
    #{File.read!(@migration)}
    do $$
    begin
      if (select nspacl from pg_namespace where nspname = 'symphony_staging')
           is distinct from (select schema_acl from aro_163_acl_before)
         or (select relacl from pg_class where oid = 'public.aro_163_acl_sentinel'::regclass)
           is distinct from (select table_acl from aro_163_acl_before)
         or (select coalesce(jsonb_agg(to_jsonb(defaults) order by defaults.oid), '[]'::jsonb)
             from pg_default_acl defaults)
           is distinct from (select default_acls from aro_163_acl_before) then
        raise exception 'shared ACL state changed during apply';
      end if;
    end
    $$;
    begin;
    set local role symphony_staging_runtime;
    set local search_path = pg_catalog, symphony_staging;
    do $$
    begin
      if current_setting('search_path') <> 'pg_catalog, symphony_staging'
         or to_regclass('routing_assignments') <>
           'symphony_staging.routing_assignments'::regclass then
        raise exception 'SET ROLE connection contract did not resolve staging safely';
      end if;
    end
    $$;
    rollback;
    #{File.read!(@rollback)}
    do $$
    begin
      if to_regclass('public.aro_163_acl_sentinel') is null
         or not has_table_privilege(
           'aro_163_acl_reader',
           'public.aro_163_acl_sentinel',
           'SELECT'
         ) then
        raise exception 'rollback changed unrelated sentinel state';
      end if;
    end
    $$;
    """)
  end

  test "unsafe pre-existing role configuration fails closed transactionally" do
    run_sql("""
    create schema symphony_staging;
    create role symphony_staging_runtime
      nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
    alter role symphony_staging_runtime set search_path = public;
    grant usage on schema symphony_staging to symphony_staging_runtime;
    """)

    {output, status} = run_psql(File.read!(@migration))

    assert status != 0
    assert output =~ "unsafe pre-existing role state"
    refute foundation_table_exists?()
  end

  defp foundation_table_exists? do
    {output, 0} =
      run_psql("select to_regclass('symphony_staging.contract_versions') is not null;")

    String.trim(output) == "t"
  end

  defp run_sql(sql) do
    {output, status} = run_psql(sql)
    assert status == 0, output
    output
  end

  defp run_psql(sql) do
    System.cmd(
      @psql,
      ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", @database_url, "-f", "-"],
      input: sql,
      stderr_to_stdout: true
    )
  end
end
