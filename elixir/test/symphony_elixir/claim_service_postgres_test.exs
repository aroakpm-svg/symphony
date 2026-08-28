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
  @issue_id "00000000-0000-4000-8000-000000002287"

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
      stop_supervisor!(resource_supervisor)

      if result != :ok, do: flunk("disposable database cleanup failed: #{inspect(result)}")
    end)

    query!(admin_connection, ~s(create database "#{database_name}"))

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

    query!(claim_connection, """
    create schema symphony_staging;

    create table symphony_staging.routing_assignments (
      issue_id uuid primary key,
      routing_policy text not null,
      target_node_id uuid,
      routing_revision bigint not null
    );

    create table symphony_staging.issue_claims (
      issue_id uuid primary key,
      claim_id uuid not null,
      generation bigint not null
    );

    create function symphony_staging.claim_issue(
      requested_issue_id text,
      requested_node_id uuid,
      requested_node_instance_id uuid,
      requested_linear_updated_at timestamptz,
      requested_issue_state text,
      requested_active_states text[],
      requested_lease_ms integer,
      requested_fallback_grace_ms integer
    ) returns table (claim_id uuid, generation bigint)
    language plpgsql
    as $$
    begin
      perform pg_sleep(0.6);

      return query
      insert into symphony_staging.issue_claims (issue_id, claim_id, generation)
      values (
        requested_issue_id::uuid,
        '00000000-0000-4000-8000-000000003287'::uuid,
        1
      )
      returning issue_claims.claim_id, issue_claims.generation;
    end
    $$;
    """)

    {:ok, claim_connection: claim_connection, update_connection: update_connection, database_name: database_name}
  end

  test "routing update waits until exclusive validation and claim acquisition commit", context do
    insert_route(context.claim_connection, "exclusive", @node_id, 7)
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
          where issue_id = $1::uuid
          """,
          [@issue_id]
        )
      end)

    assert Task.yield(update_task, 100) == nil
    assert {:reply, {:ok, %{claim_id: claim_id}}, _state} = Task.await(claim_task, 2_000)
    assert is_binary(claim_id)
    assert %Postgrex.Result{num_rows: 1} = Task.await(update_task, 2_000)
    assert claim_count(context.claim_connection) == 1
  end

  test "stale revision, policy, and node are rejected without creating a claim", context do
    cases = [
      {"exclusive", @node_id, 8},
      {"unassigned", nil, 7},
      {"preferred-with-fallback", @node_id, 7},
      {"exclusive", "00000000-0000-4000-8000-000000009999", 7}
    ]

    for {policy, node_id, revision} <- cases do
      query!(context.claim_connection, "delete from symphony_staging.routing_assignments")
      insert_route(context.claim_connection, policy, node_id, revision)

      assert {:reply, {:error, :routing_changed}, _state} =
               ClaimService.handle_call(
                 {:claim, issue(7), self()},
                 self(),
                 claim_state(context.claim_connection)
               )

      assert claim_count(context.claim_connection) == 0
    end
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

  defp insert_route(connection, policy, node_id, revision) do
    Postgrex.query!(
      connection,
      """
      insert into symphony_staging.routing_assignments (
        issue_id, routing_policy, target_node_id, routing_revision
      ) values ($1::uuid, $2, $3::uuid, $4)
      """,
      [@issue_id, policy, node_id, revision]
    )
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
            and query like '%symphony_staging.claim_issue%'
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
