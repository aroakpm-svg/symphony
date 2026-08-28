Code.require_file("../support/claim_service_postgres_harness.exs", __DIR__)

defmodule SymphonyElixir.ClaimServicePostgresTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaimService
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.ClaimServicePostgresHarness, as: Harness

  @admin_url System.get_env("ARO287_CLAIM_TEST_ADMIN_URL")
  @enabled match?({:ok, _uri}, Harness.validate_admin_url(@admin_url)) and
             System.get_env("ARO287_ALLOW_DESTRUCTIVE_DB_TEST") == "1"
  @node_id "00000000-0000-4000-8000-000000000287"
  @node_instance_id "00000000-0000-4000-8000-000000001287"
  @future_node_id "00000000-0000-4000-8000-000000000288"
  @future_node_instance_id "00000000-0000-4000-8000-000000001288"
  @issue_id "ARO-287/non-uuid"

  @moduletag skip:
               if(@enabled,
                 do: false,
                 else:
                   "set a localhost/postgres ARO287_CLAIM_TEST_ADMIN_URL and " <>
                     "ARO287_ALLOW_DESTRUCTIVE_DB_TEST=1"
               )

  setup do
    {:ok, admin_uri} = Harness.validate_admin_url(@admin_url)
    token = Harness.random_token()
    database_name = Harness.database_name(token)
    node_role = "aro287_node_#{token}"
    future_node_role = "aro287_future_node_#{token}"
    {:ok, resource_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Process.unlink(resource_supervisor)
    admin_connection = start_connection!(resource_supervisor, @admin_url)

    cleanup_state = %{
      created?: false,
      create_attempted?: true,
      admin_url: @admin_url,
      admin_connection: admin_connection,
      database_name: database_name,
      token: token,
      database_connections: [],
      marker_connection: {:fresh, resource_supervisor, Harness.database_url(admin_uri, database_name, "aro287_marker")}
    }

    on_exit(fn ->
      children = child_pids(resource_supervisor)
      state = %{cleanup_state | database_connections: Enum.reject(children, &(&1 == admin_connection))}
      result = Harness.cleanup(state, cleanup_operations(resource_supervisor))
      cleanup_admin = start_connection!(resource_supervisor, @admin_url)
      query!(cleanup_admin, ~s(drop role if exists "#{future_node_role}"))
      query!(cleanup_admin, ~s(drop role if exists "#{node_role}"))

      assert %Postgrex.Result{rows: [[0]]} =
               Postgrex.query!(
                 cleanup_admin,
                 "select count(*) from pg_roles where rolname = any($1::text[])",
                 [[node_role, future_node_role]]
               )

      stop_supervisor!(resource_supervisor)

      if result != :ok, do: flunk("disposable database cleanup failed: #{inspect(result)}")
    end)

    query!(admin_connection, ~s(create database "#{database_name}"))
    query!(admin_connection, ~s(create role "#{node_role}" noinherit login password '#{token}'))
    query!(admin_connection, ~s(grant connect on database "#{database_name}" to "#{node_role}"))

    claim_url = Harness.database_url(admin_uri, database_name, "aro287_claim_transaction")
    update_url = Harness.database_url(admin_uri, database_name, "aro287_route_update")
    claim_connection = start_connection!(resource_supervisor, claim_url)
    update_connection = start_connection!(resource_supervisor, update_url)

    query!(claim_connection, """
    create table public.aro287_disposable_run_marker (
      run_token text primary key
    );
    insert into public.aro287_disposable_run_marker (run_token) values ('#{token}');
    """)

    install_prerequisites!(claim_connection, node_role)
    apply_migration!(claim_connection, "20260804000000_aro_164_cross_machine_claims.sql")
    apply_migration!(claim_connection, "20260827000000_aro_288_node_capacity_contract.sql")
    apply_migration!(claim_connection, "20260828000000_aro_287_exclusive_route_claim_api.sql")

    query!(admin_connection, ~s(create role "#{future_node_role}" noinherit login password '#{token}'))
    query!(admin_connection, ~s(grant connect on database "#{database_name}" to "#{future_node_role}"))
    install_future_node!(claim_connection, future_node_role)
    install_claim_delay_trigger!(claim_connection)

    node_uri = %{admin_uri | userinfo: "#{node_role}:#{token}"}
    node_url = Harness.database_url(node_uri, database_name, "aro287_node_claim")
    node_connection = start_connection!(resource_supervisor, node_url)

    future_uri = %{admin_uri | userinfo: "#{future_node_role}:#{token}"}
    future_url = Harness.database_url(future_uri, database_name, "aro287_future_node_claim")
    future_connection = start_connection!(resource_supervisor, future_url)

    {:ok,
     %{
       claim_connection: node_connection,
       future_connection: future_connection,
       update_connection: update_connection,
       database_name: database_name
     }}
  end

  test "routing update waits until exclusive validation and claim acquisition commit", context do
    insert_route(context.update_connection, "exclusive", @node_id, 7)
    state = claim_state(context.claim_connection)

    claim_task =
      Task.async(fn ->
        ClaimService.handle_call({:claim, issue(7), self()}, self(), state)
      end)

    wait_until_claim_query_is_active!(context.update_connection)

    update_task =
      Task.async(fn ->
        Postgrex.query!(
          context.update_connection,
          """
          update symphony_staging.routing_assignments
          set routing_policy = 'unassigned', target_node_id = null, routing_revision = 8
          where issue_id = $1
          """,
          [@issue_id]
        )
      end)

    assert Task.yield(update_task, 100) == nil
    assert {:reply, {:ok, %{claim_id: claim_id}}, _state} = Task.await(claim_task, 2_000)
    assert is_binary(claim_id)
    assert %Postgrex.Result{num_rows: 1} = Task.await(update_task, 2_000)
    assert claim_count(context.update_connection) == 1
  end

  test "stale revision, policy, and node are rejected without creating a claim", context do
    cases = [
      {"exclusive", @node_id, 8},
      {"unassigned", nil, 7},
      {"preferred-with-fallback", @node_id, 7},
      {"exclusive", "00000000-0000-4000-8000-000000009999", 7}
    ]

    for {policy, node_id, revision} <- cases do
      query!(context.update_connection, "delete from symphony_staging.routing_assignments")
      insert_route(context.update_connection, policy, node_id, revision)

      assert {:reply, {:error, :routing_changed}, _state} =
               ClaimService.handle_call(
                 {:claim, issue(7), self()},
                 self(),
                 claim_state(context.claim_connection)
               )

      assert claim_count(context.update_connection) == 0
    end
  end

  test "existing and trigger-granted future node logins have function-only access", context do
    insert_route(context.update_connection, "exclusive", @node_id, 11, "existing/non-uuid")
    insert_route(context.update_connection, "exclusive", @future_node_id, 12, "future/non-uuid")

    assert %Postgrex.Result{rows: [["exclusive", @node_id, 11]]} =
             Postgrex.query!(
               context.claim_connection,
               "select routing_policy, target_node_id::text, routing_revision " <>
                 "from symphony_staging.exclusive_route_snapshot($1)",
               ["existing/non-uuid"]
             )

    assert %Postgrex.Result{rows: [["exclusive", @future_node_id, 12]]} =
             Postgrex.query!(
               context.future_connection,
               "select routing_policy, target_node_id::text, routing_revision " <>
                 "from symphony_staging.exclusive_route_snapshot($1)",
               ["future/non-uuid"]
             )

    future_issue = %Issue{
      id: "future/non-uuid",
      state: "In Progress",
      updated_at: DateTime.utc_now(),
      routing_revision: 12
    }

    future_state = %{
      claim_state(context.future_connection)
      | settings: %{
          node_id: @future_node_id,
          node_instance_id: @future_node_instance_id,
          lease_ms: 60_000,
          fallback_grace_ms: 30_000
        }
    }

    assert {:reply, {:ok, %{issue_id: "future/non-uuid"}}, _state} =
             ClaimService.handle_call({:claim, future_issue, self()}, self(), future_state)

    for connection <- [context.claim_connection, context.future_connection],
        table <- ["routing_assignments", "node_login_principals"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(connection, "select * from symphony_staging.#{table}", [])
    end

    query!(context.update_connection, "update symphony_staging.nodes set status = 'inactive' where node_id = '#{@future_node_id}'")

    assert {:error, %Postgrex.Error{postgres: %{code: :invalid_authorization_specification}}} =
             Postgrex.query(
               context.future_connection,
               "select * from symphony_staging.exclusive_route_snapshot($1)",
               ["future/non-uuid"]
             )
  end

  defp claim_state(connection) do
    %ClaimService{
      connection: connection,
      settings: %{
        node_id: @node_id,
        node_instance_id: @node_instance_id,
        lease_ms: 60_000,
        fallback_grace_ms: 30_000
      }
    }
  end

  defp issue(revision) do
    %Issue{
      id: @issue_id,
      state: "In Progress",
      updated_at: DateTime.utc_now(),
      routing_revision: revision
    }
  end

  defp insert_route(connection, policy, node_id, revision, issue_id \\ @issue_id) do
    Postgrex.query!(
      connection,
      """
      insert into symphony_staging.routing_assignments (
        issue_id, routing_policy, target_node_id, routing_revision, contract_version
      ) values ($1, $2, $3::uuid, $4, 1)
      """,
      [issue_id, policy, node_id, revision]
    )
  end

  defp apply_migration!(connection, filename) do
    path = Path.expand("../../priv/symphony_migrations/#{filename}", __DIR__)
    query!(connection, File.read!(path))
  end

  defp install_prerequisites!(connection, node_role) do
    query!(connection, """
    do $$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
      if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
      if not exists (select 1 from pg_roles where rolname = 'symphony_staging_runtime') then
        create role symphony_staging_runtime nologin;
      end if;
      if not exists (select 1 from pg_roles where rolname = 'symphony_staging_provisioner') then
        create role symphony_staging_provisioner nologin;
      end if;
    end $$;
    create schema symphony_staging;
    grant usage on schema symphony_staging to symphony_staging_runtime,
      symphony_staging_provisioner, "#{node_role}";
    create table symphony_staging.contract_versions (
      contract_name text primary key, contract_version integer not null,
      migration_name text not null, installed_at timestamptz not null default clock_timestamp()
    );
    create table symphony_staging.nodes (
      node_id uuid primary key, display_alias text, status text not null,
      credential_version integer not null default 1, created_at timestamptz default clock_timestamp(),
      updated_at timestamptz default clock_timestamp(), rotated_at timestamptz,
      revoked_at timestamptz, retired_at timestamptz
    );
    create table symphony_staging.routing_assignments (
      issue_id text primary key, routing_policy text not null,
      target_node_id uuid references symphony_staging.nodes,
      routing_revision bigint not null, contract_version integer not null,
      updated_at timestamptz not null default clock_timestamp()
    );
    create table symphony_staging.node_login_principals (
      node_id uuid primary key references symphony_staging.nodes,
      login_role name not null unique, created_at timestamptz default clock_timestamp(),
      revoked_at timestamptz
    );
    create table symphony_staging.active_node_instances (
      node_id uuid primary key references symphony_staging.node_login_principals,
      node_instance_id uuid not null, authenticated_at timestamptz default clock_timestamp(),
      unique (node_id, node_instance_id)
    );
    insert into symphony_staging.nodes(node_id, display_alias, status) values
      ('#{@node_id}', 'existing', 'active');
    insert into symphony_staging.node_login_principals(node_id, login_role) values
      ('#{@node_id}', '#{node_role}');
    insert into symphony_staging.active_node_instances(node_id, node_instance_id) values
      ('#{@node_id}', '#{@node_instance_id}');
    """)
  end

  defp install_future_node!(connection, future_node_role) do
    query!(connection, """
    grant usage on schema symphony_staging to "#{future_node_role}";
    insert into symphony_staging.nodes(node_id, display_alias, status, claim_capacity) values
      ('#{@future_node_id}', 'future', 'active', 1);
    insert into symphony_staging.node_login_principals(node_id, login_role) values
      ('#{@future_node_id}', '#{future_node_role}');
    insert into symphony_staging.active_node_instances(node_id, node_instance_id) values
      ('#{@future_node_id}', '#{@future_node_instance_id}');
    """)
  end

  defp install_claim_delay_trigger!(connection) do
    query!(connection, """
    create function public.aro287_delay_claim() returns trigger language plpgsql as $$
    begin perform pg_sleep(0.6); return new; end $$;
    create trigger aro287_delay_claim before insert or update on symphony_staging.issue_claims
    for each row execute function public.aro287_delay_claim();
    """)
  end

  defp wait_until_claim_query_is_active!(connection, attempts \\ 50)

  defp wait_until_claim_query_is_active!(_connection, 0),
    do: flunk("claim transaction never reached the acquisition query")

  defp wait_until_claim_query_is_active!(connection, attempts) do
    result =
      Postgrex.query!(
        connection,
        """
        select exists (
          select 1
          from pg_stat_activity
          where application_name = 'aro287_claim_transaction'
            and state = 'active'
            and query like '%symphony_staging.claim_exclusive_issue%'
        )
        """,
        []
      )

    case result.rows do
      [[true]] ->
        :ok

      [[false]] ->
        Process.sleep(20)
        wait_until_claim_query_is_active!(connection, attempts - 1)
    end
  end

  defp claim_count(connection) do
    %Postgrex.Result{rows: [[count]]} =
      Postgrex.query!(connection, "select count(*) from symphony_staging.issue_claims", [])

    count
  end

  defp cleanup_operations(resource_supervisor) do
    %{
      marker: fn {:fresh, supervisor, url}, token ->
        Harness.verify_fresh_marker(
          fn -> start_connection!(supervisor, url) end,
          fn connection, expected_token ->
            case Postgrex.query!(
                   connection,
                   "select run_token from public.aro287_disposable_run_marker",
                   []
                 ) do
              %Postgrex.Result{rows: [[^expected_token]]} -> :ok
              _result -> {:error, :marker_mismatch}
            end
          end,
          &stop_connection!/1,
          token
        )
      end,
      stop: &stop_connection!/1,
      ensure_admin: fn connection, admin_url ->
        ensure_admin_connection(resource_supervisor, connection, admin_url)
      end,
      terminate: fn admin, sql, params -> Postgrex.query!(admin, sql, params) end,
      drop: fn admin, sql -> Postgrex.query!(admin, sql, []) end
    }
  end

  defp ensure_admin_connection(supervisor, connection, admin_url) do
    if Process.alive?(connection) do
      try do
        Postgrex.query!(connection, "select 1", [])
        {:ok, connection}
      rescue
        _exception -> reconnect_admin(supervisor, connection, admin_url)
      catch
        :exit, _reason -> reconnect_admin(supervisor, connection, admin_url)
      end
    else
      reconnect_admin(supervisor, connection, admin_url)
    end
  end

  defp reconnect_admin(supervisor, connection, admin_url) do
    stop_connection!(connection)
    {:ok, start_connection!(supervisor, admin_url)}
  end

  defp start_connection!(supervisor, url) do
    child_spec = %{
      id: make_ref(),
      start: {Postgrex, :start_link, [[url: url]]},
      restart: :temporary
    }

    {:ok, connection} = DynamicSupervisor.start_child(supervisor, child_spec)
    connection
  end

  defp child_pids(supervisor) do
    if Process.alive?(supervisor) do
      DynamicSupervisor.which_children(supervisor) |> Enum.map(&elem(&1, 1))
    else
      []
    end
  end

  defp stop_supervisor!(supervisor) do
    if Process.alive?(supervisor), do: DynamicSupervisor.stop(supervisor, :normal, 5_000)
  end

  defp stop_connection!(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection, :normal, 5_000)
  end

  defp query!(connection, sql), do: Postgrex.query!(connection, sql, [])
end
