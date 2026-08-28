Code.require_file("../support/claim_service_postgres_harness.exs", __DIR__)

defmodule SymphonyElixir.ClaimServicePostgresHarnessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.ClaimServicePostgresHarness, as: Harness

  test "accepts only a localhost postgres admin database" do
    for url <- [
          "postgresql://postgres:secret@localhost:5432/postgres",
          "postgres://postgres@127.0.0.1/postgres",
          "postgresql://postgres@[::1]:5432/postgres"
        ] do
      assert {:ok, _uri} = Harness.validate_admin_url(url)
    end

    for url <- [
          "postgresql://postgres@database.internal/postgres",
          "postgresql://postgres@localhost/production",
          "postgresql://postgres@localhost/template1",
          "https://localhost/postgres",
          "not-a-url"
        ] do
      assert {:error, :unsafe_admin_database_url} = Harness.validate_admin_url(url)
    end
  end

  test "database names require the exact current-run random token" do
    token = "0123456789abcdef0123456789abcdef"
    name = Harness.database_name(token)

    assert name == "aro287_claim_test_0123456789abcdef0123456789abcdef"
    assert :ok = Harness.validate_cleanup_target(name, token)

    for unsafe_token <- ["short", "../../postgres", "ABCDEF0123456789ABCDEF0123456789"] do
      assert_raise ArgumentError, fn -> Harness.database_name(unsafe_token) end
    end

    for unsafe <- [
          "postgres",
          "symphony_staging",
          "aro287_claim_test_#{token}_other",
          "aro287_claim_test_../../postgres",
          "aro287_claim_test_ABCDEF0123456789ABCDEF0123456789"
        ] do
      assert {:error, :unsafe_cleanup_target} = Harness.validate_cleanup_target(unsafe, token)
    end
  end

  test "cleanup statements terminate and drop only the exact validated database" do
    token = "fedcba9876543210fedcba9876543210"
    name = Harness.database_name(token)

    assert {:ok, %{terminate_sql: terminate_sql, terminate_params: [^name], drop_sql: drop_sql}} =
             Harness.cleanup_statements(name, token)

    assert terminate_sql =~ "where datname = $1"
    assert drop_sql == ~s(drop database if exists "#{name}")
    refute terminate_sql =~ name
  end

  test "cleanup after create attempts exact termination and drop with no target connections" do
    events = start_supervised!({Agent, fn -> [] end})
    state = cleanup_state(database_connections: [], marker_connection: nil)

    assert :ok = Harness.cleanup(state, cleanup_ops(events))

    assert Agent.get(events, &Enum.reverse/1) == [
             {:ensure_admin, :dead_admin, state.admin_url},
             {:terminate, :reconnected_admin, [state.database_name]},
             {:ensure_admin, :reconnected_admin, state.admin_url},
             {:drop, :reconnected_admin, ~s(drop database if exists "#{state.database_name}")},
             {:stop, :reconnected_admin}
           ]
  end

  test "uncertain create outcome still cleans the exact attempted database" do
    events = start_supervised!({Agent, fn -> [] end})
    state = cleanup_state(created?: false, create_attempted?: true, database_connections: [], marker_connection: nil)

    assert :ok = Harness.cleanup(state, cleanup_ops(events))

    assert Agent.get(events, &Enum.reverse/1)
           |> Enum.any?(fn
             {:drop, :reconnected_admin, sql} -> sql == ~s(drop database if exists "#{state.database_name}")
             _event -> false
           end)
  end

  test "dead cleanup owner falls back to immutable attempted ownership state" do
    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

    fallback = cleanup_state(created?: false, create_attempted?: true)
    assert Harness.owner_state(owner, fallback) == fallback
  end

  test "dead marker, stop failure, and terminate failure cannot skip exact drop" do
    events = start_supervised!({Agent, fn -> [] end})
    state = cleanup_state(database_connections: [:dead_marker, :stop_fails], marker_connection: :dead_marker)

    ops =
      cleanup_ops(events,
        marker: fn _connection, _token -> raise "marker connection dead" end,
        stop: fn
          :stop_fails -> raise "stop failed"
          connection -> record(events, {:stop, connection})
        end,
        terminate: fn admin, _sql, params ->
          record(events, {:terminate, admin, params})
          {:error, :terminate_failed}
        end
      )

    assert {:error, errors} = Harness.cleanup(state, ops)
    assert length(errors) == 3

    assert Agent.get(events, &Enum.reverse/1) == [
             {:stop, :dead_marker},
             {:ensure_admin, :dead_admin, state.admin_url},
             {:terminate, :reconnected_admin, [state.database_name]},
             {:ensure_admin, :reconnected_admin, state.admin_url},
             {:drop, :reconnected_admin, ~s(drop database if exists "#{state.database_name}")},
             {:stop, :reconnected_admin}
           ]
  end

  test "admin reconnect failure is reported after all possible independent cleanup steps" do
    events = start_supervised!({Agent, fn -> [] end})
    state = cleanup_state(database_connections: [:claim], marker_connection: nil)

    ops =
      cleanup_ops(events,
        ensure_admin: fn existing, url ->
          record(events, {:ensure_admin, existing, url})
          {:error, :admin_unavailable}
        end
      )

    assert {:error, errors} = Harness.cleanup(state, ops)
    assert errors == [admin_terminate: :admin_unavailable, admin_drop: :admin_unavailable]

    assert Agent.get(events, &Enum.reverse/1) == [
             {:stop, :claim},
             {:ensure_admin, :dead_admin, state.admin_url},
             {:ensure_admin, :dead_admin, state.admin_url}
           ]
  end

  test "a readable mismatched marker stops connections but refuses database deletion" do
    events = start_supervised!({Agent, fn -> [] end})
    state = cleanup_state(database_connections: [:claim], marker_connection: :claim)

    ops = cleanup_ops(events, marker: fn _connection, _token -> {:error, :marker_mismatch} end)

    assert {:error, [marker: :marker_mismatch]} = Harness.cleanup(state, ops)
    assert Agent.get(events, &Enum.reverse/1) == [{:stop, :claim}, {:stop, :dead_admin}]
  end

  defp cleanup_state(overrides) do
    token = "0123456789abcdef0123456789abcdef"

    Map.merge(
      %{
        created?: true,
        create_attempted?: true,
        admin_url: "postgresql://postgres@localhost/postgres",
        admin_connection: :dead_admin,
        database_name: Harness.database_name(token),
        token: token,
        database_connections: [],
        marker_connection: nil
      },
      Map.new(overrides)
    )
  end

  defp cleanup_ops(events, overrides \\ []) do
    defaults = [
      marker: fn connection, token ->
        record(events, {:marker, connection, token})
        :ok
      end,
      stop: fn connection -> record(events, {:stop, connection}) end,
      ensure_admin: fn existing, url ->
        record(events, {:ensure_admin, existing, url})
        {:ok, :reconnected_admin}
      end,
      terminate: fn admin, _sql, params -> record(events, {:terminate, admin, params}) end,
      drop: fn admin, sql -> record(events, {:drop, admin, sql}) end
    ]

    defaults |> Keyword.merge(overrides) |> Map.new()
  end

  defp record(events, event), do: Agent.update(events, &[event | &1])
end
