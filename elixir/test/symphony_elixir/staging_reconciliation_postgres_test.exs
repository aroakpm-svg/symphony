defmodule SymphonyElixir.StagingReconciliationPostgresTest do
  use ExUnit.Case, async: false

  @foundation Path.expand(
                "../../priv/symphony_migrations/20260723000000_aro_163_staging_foundation.sql",
                __DIR__
              )
  @migration Path.expand(
               "../../priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.down.sql",
              __DIR__
            )

  @database_url System.get_env("ARO168_MIGRATION_TEST_DATABASE_URL")
  @psql_wrapper System.get_env("ARO168_PSQL_WRAPPER")
  @psql if(@psql_wrapper in [nil, ""],
          do: System.find_executable("psql"),
          else: System.find_executable("node")
        )
  @psql_prefix_args if(@psql_wrapper in [nil, ""], do: [], else: [@psql_wrapper])
  @enabled @database_url not in [nil, ""] and @psql != nil and
             System.get_env("ARO168_ALLOW_DESTRUCTIVE_DB_TEST") == "1"

  @moduletag skip:
               if(@enabled,
                 do: false,
                 else:
                   "set ARO168_MIGRATION_TEST_DATABASE_URL and " <>
                     "ARO168_ALLOW_DESTRUCTIVE_DB_TEST=1 with psql on PATH"
               )

  setup do
    reset_database()
    install_legacy_profile()
    on_exit(&reset_database/0)
    :ok
  end

  test "apply, rollback, and reapply preserve the approved lifecycle" do
    run_sql(File.read!(@migration))
    assert contract_version() == "2|20260724000000_aro_168_staging_reconciliation"

    run_sql(File.read!(@rollback))
    assert contract_version() == "1|20260723000000_aro_163_staging_foundation"

    run_sql(File.read!(@migration))
    assert contract_version() == "2|20260724000000_aro_168_staging_reconciliation"

    assert run_sql("""
           select count(*)
           from pg_roles
           where rolname in (
             'symphony_staging_runtime',
             'symphony_staging_provisioner'
           );
           """)
           |> String.trim() == "2"

    assert run_sql("""
           select count(*)
           from pg_policies
           where schemaname = 'symphony_staging'
             and permissive = 'PERMISSIVE'
             and policyname in (
               'runtime_read_contract_versions',
               'provisioner_manage_contract_versions'
             )
             and qual =
               '(contract_name !~~ ''aro-163-created-role:%''::text)';
           """)
           |> String.trim() == "2"
  end

  test "every reviewed catalog drift fails before the v2 contract write" do
    drift_cases = [
      {"disabled RLS", "alter table symphony_staging.contract_versions disable row level security;"},
      {"forced RLS", "alter table symphony_staging.contract_versions force row level security;"},
      {"restrictive policy",
       """
       drop policy runtime_read_contract_versions
         on symphony_staging.contract_versions;
       create policy runtime_read_contract_versions
         on symphony_staging.contract_versions
         as restrictive
         for select
         to symphony_staging_runtime
         using (true);
       """},
      {"disabled trigger",
       """
       alter table symphony_staging.routing_assignments
         disable trigger enforce_routing_revision;
       """},
      {"missing trigger",
       """
       drop trigger enforce_node_transition
         on symphony_staging.nodes;
       """},
      {"production view", "create view symphony_production.drift_view as select 1 as id;"},
      {"production sequence", "create sequence symphony_production.drift_sequence;"},
      {"runtime verifier disclosure",
       """
       grant select (credential_verifier)
         on symphony_staging.node_bindings
         to symphony_staging_runtime;
       """},
      {"unexpected table grant",
       """
       grant delete on symphony_staging.nodes
         to symphony_staging_provisioner;
       """},
      {"function execute grant",
       """
       grant execute on function symphony_staging.enforce_node_transition()
         to symphony_staging_runtime;
       """}
    ]

    Enum.with_index(drift_cases)
    |> Enum.each(fn {{label, drift_sql}, index} ->
      if index > 0 do
        reset_database()
        install_legacy_profile()
      end

      run_sql(drift_sql)
      {output, status} = run_psql(File.read!(@migration))

      assert status != 0, "#{label} unexpectedly passed"
      assert output =~ "ARO-168", "#{label} did not fail through an ARO-168 gate: #{output}"
      assert contract_version() == "1|20260723000000_aro_163_staging_foundation"

      assert run_sql("""
             select rolconfig
             from pg_roles
             where rolname = 'symphony_staging_runtime';
             """)
             |> String.trim() == "{\"search_path=pg_catalog, symphony_staging\"}"
    end)
  end

  defp install_legacy_profile do
    run_sql("""
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    create schema symphony_production;
    #{File.read!(@foundation)}
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
    """)
  end

  defp reset_database do
    run_sql("""
    drop schema if exists symphony_staging cascade;
    drop schema if exists symphony_production cascade;
    drop role if exists symphony_staging_runtime;
    drop role if exists symphony_staging_provisioner;
    drop role if exists anon;
    drop role if exists authenticated;
    drop role if exists service_role;
    """)
  end

  defp contract_version do
    run_sql("""
    select contract_version || '|' || migration_name
    from symphony_staging.contract_versions
    where contract_name = 'node-identity-routing-foundation';
    """)
    |> String.trim()
  end

  defp run_sql(sql) do
    {output, status} = run_psql(sql)
    assert status == 0, output
    output
  end

  defp run_psql(sql) do
    sql_path =
      Path.join(
        System.tmp_dir!(),
        "aro_168_staging_reconciliation_#{System.unique_integer([:positive])}.sql"
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
