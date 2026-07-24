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
  @psql_wrapper System.get_env("ARO163_PSQL_WRAPPER")
  @psql if(@psql_wrapper in [nil, ""],
          do: System.find_executable("psql"),
          else: System.find_executable("node")
        )
  @psql_prefix_args if(@psql_wrapper in [nil, ""], do: [], else: [@psql_wrapper])
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
    run_sql("""
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    """)

    on_exit(fn ->
      run_sql("""
      drop schema if exists symphony_staging cascade;
      drop schema if exists symphony_production cascade;
      drop table if exists public.aro_163_acl_sentinel;
      drop role if exists aro_163_acl_reader;
      drop role if exists symphony_staging_runtime;
      drop role if exists symphony_staging_provisioner;
      drop role if exists anon;
      drop role if exists authenticated;
      drop role if exists service_role;
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
      (select coalesce(
         jsonb_agg(to_jsonb(acl) order by
           acl.grantor,
           acl.grantee,
           acl.privilege_type,
           acl.is_grantable
         ),
         '[]'::jsonb
       )
       from pg_namespace namespace
       cross join lateral aclexplode(
         coalesce(namespace.nspacl, acldefault('n', namespace.nspowner))
       ) acl
       where namespace.nspname = 'symphony_staging') as unrelated_schema_acl,
      (select relacl from pg_class where oid = 'public.aro_163_acl_sentinel'::regclass) as table_acl,
      (select coalesce(jsonb_agg(to_jsonb(defaults) order by defaults.oid), '[]'::jsonb)
       from pg_default_acl defaults) as default_acls;
    #{File.read!(@migration)}
    do $$
    begin
      if (select coalesce(
            jsonb_agg(to_jsonb(acl) order by
              acl.grantor,
              acl.grantee,
              acl.privilege_type,
              acl.is_grantable
            ),
            '[]'::jsonb
          )
          from pg_namespace namespace
          cross join lateral aclexplode(
            coalesce(namespace.nspacl, acldefault('n', namespace.nspowner))
          ) acl
          where namespace.nspname = 'symphony_staging'
            and acl.grantee not in (
              'symphony_staging_runtime'::regrole::oid,
              'symphony_staging_provisioner'::regrole::oid
            ))
           is distinct from (select unrelated_schema_acl from aro_163_acl_before)
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
           'symphony_staging.routing_assignments'::regclass
         or exists (
           select 1
           from symphony_staging.contract_versions
           where contract_name like 'aro-163-created-role:%'
         ) then
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
         )
         or (select coalesce(
               jsonb_agg(to_jsonb(acl) order by
                 acl.grantor,
                 acl.grantee,
                 acl.privilege_type,
                 acl.is_grantable
               ),
               '[]'::jsonb
             )
             from pg_namespace namespace
             cross join lateral aclexplode(
               coalesce(namespace.nspacl, acldefault('n', namespace.nspowner))
             ) acl
             where namespace.nspname = 'symphony_staging')
           is distinct from (select unrelated_schema_acl from aro_163_acl_before) then
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

  test "pre-existing schema grant option fails closed transactionally" do
    run_sql("""
    create schema symphony_staging;
    create role symphony_staging_runtime
      nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
    grant usage on schema symphony_staging
      to symphony_staging_runtime with grant option;
    """)

    {output, status} = run_psql(File.read!(@migration))

    assert status != 0
    assert output =~ "incompatible pre-existing schema grants"
    refute foundation_table_exists?()

    assert run_sql(
             "select has_schema_privilege(" <>
               "'symphony_staging_runtime', " <>
               "'symphony_staging', " <>
               "'USAGE WITH GRANT OPTION');"
           )
           |> String.trim() == "t"
  end

  test "apply repairs SET FALSE on an accepted pre-existing role membership" do
    run_sql("""
    create schema symphony_staging;
    create role symphony_staging_runtime
      nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;
    grant usage on schema symphony_staging to symphony_staging_runtime;
    grant symphony_staging_runtime to postgres with set false;
    """)

    run_sql(File.read!(@migration))

    assert run_sql("""
           select membership.set_option
           from pg_auth_members membership
           join pg_roles granted_role on granted_role.oid = membership.roleid
           join pg_roles member_role on member_role.oid = membership.member
           where granted_role.rolname = 'symphony_staging_runtime'
             and member_role.rolname = 'postgres';
           """)
           |> String.trim() == "t"

    run_sql("""
    begin;
    set local role symphony_staging_runtime;
    do $$
    begin
      if current_role <> 'symphony_staging_runtime' then
        raise exception 'SET FALSE membership was not repaired';
      end if;
    end
    $$;
    rollback;
    """)
  end

  test "canonical grants and least-privilege actors prove the installed contract" do
    run_sql("""
    create schema symphony_staging;
    create schema symphony_production;
    create temporary table aro_163_production_acl_before as
    select nspacl from pg_namespace where nspname = 'symphony_production';
    #{File.read!(@migration)}
    #{File.read!(@migration)}
    do $$
    declare
      checked_role record;
    begin
      for checked_role in
        select rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit,
               rolreplication, rolbypassrls
        from pg_roles
        where rolname in ('symphony_staging_runtime', 'symphony_staging_provisioner')
      loop
        if checked_role.rolcanlogin or checked_role.rolsuper or checked_role.rolcreatedb
           or checked_role.rolcreaterole or checked_role.rolinherit
           or checked_role.rolreplication or checked_role.rolbypassrls then
          raise exception 'unsafe canonical role attributes for %', checked_role.rolname;
        end if;
      end loop;

      if (select count(*) from pg_roles
          where rolname in ('symphony_staging_runtime', 'symphony_staging_provisioner')) <> 2
         or (select count(*)
             from pg_auth_members membership
             join pg_roles granted_role on granted_role.oid = membership.roleid
             join pg_roles member_role on member_role.oid = membership.member
             where granted_role.rolname in (
               'symphony_staging_runtime', 'symphony_staging_provisioner'
             )
               and member_role.rolname = 'postgres'
               and membership.set_option) <> 2
         or exists (
           select 1
           from pg_auth_members membership
           join pg_roles granted_role on granted_role.oid = membership.roleid
           join pg_roles member_role on member_role.oid = membership.member
           where granted_role.rolname in (
             'symphony_staging_runtime', 'symphony_staging_provisioner'
           )
             and (member_role.rolname <> 'postgres' or not membership.set_option)
         ) then
        raise exception 'canonical role membership state is invalid';
      end if;

      if not has_schema_privilege(
           'symphony_staging_runtime', 'symphony_staging', 'USAGE'
         )
         or has_schema_privilege(
           'symphony_staging_runtime', 'symphony_staging', 'CREATE'
         )
         or not has_column_privilege(
           'symphony_staging_runtime',
           'symphony_staging.nodes',
           'node_id',
           'SELECT'
         )
         or has_table_privilege(
           'symphony_staging_runtime', 'symphony_staging.nodes', 'UPDATE'
         )
         or has_column_privilege(
           'symphony_staging_runtime',
           'symphony_staging.node_bindings',
           'credential_verifier',
           'SELECT'
         )
         or not has_table_privilege(
           'symphony_staging_provisioner', 'symphony_staging.nodes', 'INSERT'
         )
         or has_table_privilege('anon', 'symphony_staging.nodes', 'SELECT')
         or has_table_privilege('authenticated', 'symphony_staging.nodes', 'SELECT') then
        raise exception 'canonical object ACL state is invalid';
      end if;

      if exists (
           with expected(
             tablename, policyname, permissive, roles, cmd, qual, with_check
           ) as (
             values
               (
                 'contract_versions',
                 'runtime_read_contract_versions',
                 'PERMISSIVE',
                 array['symphony_staging_runtime']::name[],
                 'SELECT',
                 '(contract_name !~~ ''aro-163-created-role:%''::text)',
                 null
               ),
               (
                 'nodes', 'runtime_read_nodes', 'PERMISSIVE',
                 array['symphony_staging_runtime']::name[], 'SELECT', 'true', null
               ),
               (
                 'node_bindings', 'runtime_read_node_bindings', 'PERMISSIVE',
                 array['symphony_staging_runtime']::name[], 'SELECT', 'true', null
               ),
               (
                 'routing_assignments', 'runtime_read_routing_assignments', 'PERMISSIVE',
                 array['symphony_staging_runtime']::name[], 'SELECT', 'true', null
               ),
               (
                 'foundation_audit_events', 'runtime_insert_audit_events', 'PERMISSIVE',
                 array['symphony_staging_runtime']::name[], 'INSERT', null, 'true'
               ),
               (
                 'contract_versions',
                 'provisioner_manage_contract_versions',
                 'PERMISSIVE',
                 array['symphony_staging_provisioner']::name[],
                 'ALL',
                 '(contract_name !~~ ''aro-163-created-role:%''::text)',
                 '(contract_name !~~ ''aro-163-created-role:%''::text)'
               ),
               (
                 'nodes', 'provisioner_manage_nodes', 'PERMISSIVE',
                 array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'
               ),
               (
                 'node_bindings', 'provisioner_manage_node_bindings', 'PERMISSIVE',
                 array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'
               ),
               (
                 'routing_assignments', 'provisioner_manage_routing_assignments', 'PERMISSIVE',
                 array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'
               ),
               (
                 'foundation_audit_events', 'provisioner_insert_audit_events', 'PERMISSIVE',
                 array['symphony_staging_provisioner']::name[], 'INSERT', null, 'true'
               )
           ),
           actual as (
             select
               tablename, policyname, permissive, roles, cmd, qual, with_check
             from pg_policies
             where schemaname = 'symphony_staging'
           )
           (select * from expected except select * from actual)
           union all
           (select * from actual except select * from expected)
         )
         or (select nspacl from pg_namespace where nspname = 'symphony_production')
           is distinct from (select nspacl from aro_163_production_acl_before) then
        raise exception 'canonical policy or production ACL state is invalid';
      end if;
    end
    $$;
    """)

    run_sql("""
    begin;
    set local role symphony_staging_provisioner;
    set local search_path = pg_catalog, symphony_staging;
    insert into symphony_staging.nodes (
      node_id, display_alias, status, credential_version
    ) values ('00000000-0000-4000-8000-000000000163', 'contract-test', 'active', 1);
    insert into symphony_staging.node_bindings (
      binding_id, node_id, environment, status, credential_version,
      credential_verifier, activated_at
    ) values (
      '00000000-0000-4000-8000-000000001163',
      '00000000-0000-4000-8000-000000000163',
      'staging', 'active', 1, repeat('ab', 32), clock_timestamp()
    );
    insert into symphony_staging.routing_assignments (
      issue_id, routing_policy, target_node_id, routing_revision, contract_version
    ) values (
      'ARO-163', 'exclusive', '00000000-0000-4000-8000-000000000163', 1, 1
    );
    update symphony_staging.nodes
    set display_alias = 'contract-test-updated'
    where node_id = '00000000-0000-4000-8000-000000000163';
    insert into symphony_staging.foundation_audit_events (
      event_type, node_id, result, reason_code
    ) values (
      'provisioner-contract-test',
      '00000000-0000-4000-8000-000000000163',
      'accepted', 'contract-test'
    );
    commit;
    """)

    assert run_sql("""
           select
             node.display_alias,
             binding.status,
             routing.routing_policy,
             routing.routing_revision,
             count(audit.audit_id)
           from symphony_staging.nodes node
           join symphony_staging.node_bindings binding using (node_id)
           join symphony_staging.routing_assignments routing
             on routing.target_node_id = node.node_id
           join symphony_staging.foundation_audit_events audit using (node_id)
           where node.node_id = '00000000-0000-4000-8000-000000000163'
           group by
             node.display_alias,
             binding.status,
             routing.routing_policy,
             routing.routing_revision;
           """)
           |> String.trim() == "contract-test-updated|active|exclusive|1|1"

    runtime_output =
      run_sql("""
      begin;
      set local role symphony_staging_runtime;
      set local search_path = pg_catalog, symphony_staging;
      select
        node.node_id,
        node.display_alias,
        binding.binding_id,
        routing.issue_id,
        routing.routing_revision
      from symphony_staging.nodes node
      join symphony_staging.node_bindings binding using (node_id)
      join symphony_staging.routing_assignments routing
        on routing.target_node_id = node.node_id
      where node.node_id = '00000000-0000-4000-8000-000000000163';
      insert into symphony_staging.foundation_audit_events (
        event_type, node_id, result, reason_code
      ) values (
        'runtime-contract-test',
        '00000000-0000-4000-8000-000000000163',
        'accepted', 'contract-test'
      );
      commit;
      """)

    assert runtime_output =~
             "00000000-0000-4000-8000-000000000163|" <>
               "contract-test-updated|" <>
               "00000000-0000-4000-8000-000000001163|ARO-163|1"

    assert run_sql("""
           select count(*)
           from symphony_staging.foundation_audit_events
           where node_id = '00000000-0000-4000-8000-000000000163'
             and event_type in ('provisioner-contract-test', 'runtime-contract-test');
           """)
           |> String.trim() == "2"

    assert_sql_denied("""
    begin;
    set local role symphony_staging_runtime;
    update symphony_staging.nodes
    set display_alias = 'forbidden'
    where node_id = '00000000-0000-4000-8000-000000000163';
    """)

    assert_sql_denied("""
    begin;
    set local role symphony_staging_runtime;
    select credential_verifier from symphony_staging.node_bindings;
    """)

    assert_sql_denied("""
    begin;
    set local role symphony_staging_provisioner;
    insert into symphony_staging.contract_versions (
      contract_name, contract_version, migration_name
    ) values ('aro-163-created-role:forged', 1, 'forbidden');
    """)

    for actor <- ["anon", "authenticated"] do
      assert_sql_denied("""
      begin;
      set local role #{actor};
      select * from symphony_staging.nodes;
      """)
    end

    for actor <- [
          "symphony_staging_runtime",
          "symphony_staging_provisioner",
          "anon",
          "authenticated"
        ] do
      assert_sql_denied("""
      begin;
      set local role #{actor};
      create table symphony_production.forbidden (id integer);
      """)
    end

    run_sql("""
    #{File.read!(@rollback)}
    #{File.read!(@migration)}
    do $$
    begin
      if (select count(*)
          from pg_auth_members membership
          join pg_roles granted_role on granted_role.oid = membership.roleid
          join pg_roles member_role on member_role.oid = membership.member
          where granted_role.rolname in (
            'symphony_staging_runtime', 'symphony_staging_provisioner'
          )
            and member_role.rolname = 'postgres'
            and membership.set_option) <> 2
         or (select nspacl from pg_namespace where nspname = 'symphony_production')
           is not null then
        raise exception 'rollback and reapply changed canonical privilege state';
      end if;
    end
    $$;
    """)
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

  defp assert_sql_denied(sql) do
    {output, status} = run_psql(sql)
    assert status != 0, "expected permission denial, command succeeded"
    assert output =~ ~r/(permission denied|violates row-level security)/i, output
  end

  defp run_psql(sql) do
    sql_path =
      Path.join(
        System.tmp_dir!(),
        "aro_163_staging_foundation_#{System.unique_integer([:positive])}.sql"
      )

    File.write!(sql_path, sql)

    try do
      System.cmd(
        @psql,
        @psql_prefix_args ++
          [
            "-X",
            "-q",
            "-A",
            "-t",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            @database_url,
            "-f",
            sql_path
          ],
        stderr_to_stdout: true
      )
    after
      File.rm(sql_path)
    end
  end
end
