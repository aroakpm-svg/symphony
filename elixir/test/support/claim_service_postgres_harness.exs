defmodule SymphonyElixir.TestSupport.ClaimServicePostgresHarness do
  @moduledoc false

  @database_prefix "aro287_claim_test_"
  @token_pattern ~r/\A[0-9a-f]{32}\z/
  @safe_hosts MapSet.new(["localhost", "127.0.0.1", "::1"])

  @spec validate_admin_url(String.t() | nil) :: {:ok, URI.t()} | {:error, :unsafe_admin_database_url}
  def validate_admin_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["postgres", "postgresql"] and
         is_binary(uri.host) and
         MapSet.member?(@safe_hosts, String.downcase(uri.host)) and
         uri.path == "/postgres" do
      {:ok, uri}
    else
      {:error, :unsafe_admin_database_url}
    end
  end

  def validate_admin_url(_url), do: {:error, :unsafe_admin_database_url}

  @spec random_token() :: String.t()
  def random_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @spec database_name(String.t()) :: String.t()
  def database_name(token) when is_binary(token) do
    if Regex.match?(@token_pattern, token) do
      @database_prefix <> token
    else
      raise ArgumentError, "unsafe disposable database token"
    end
  end

  @spec database_url(URI.t(), String.t(), String.t()) :: String.t()
  def database_url(%URI{} = admin_uri, database_name, application_name) do
    admin_uri
    |> Map.put(:path, "/#{database_name}")
    |> Map.put(:query, URI.encode_query(%{"application_name" => application_name}))
    |> URI.to_string()
  end

  @spec validate_cleanup_target(String.t(), String.t()) :: :ok | {:error, :unsafe_cleanup_target}
  def validate_cleanup_target(database_name, token)
      when is_binary(database_name) and is_binary(token) do
    if Regex.match?(@token_pattern, token) and database_name == @database_prefix <> token,
      do: :ok,
      else: {:error, :unsafe_cleanup_target}
  end

  def validate_cleanup_target(_database_name, _token), do: {:error, :unsafe_cleanup_target}

  @spec cleanup_statements(String.t(), String.t()) ::
          {:ok, %{terminate_sql: String.t(), terminate_params: [String.t()], drop_sql: String.t()}}
          | {:error, :unsafe_cleanup_target}
  def cleanup_statements(database_name, token) do
    with :ok <- validate_cleanup_target(database_name, token) do
      {:ok,
       %{
         terminate_sql: """
         select pg_terminate_backend(pid)
         from pg_stat_activity
         where datname = $1 and pid <> pg_backend_pid()
         """,
         terminate_params: [database_name],
         drop_sql: ~s(drop database if exists "#{database_name}")
       }}
    end
  end

  @spec verify_fresh_marker((-> term()), (term(), String.t() -> term()), (term() -> term()), String.t()) :: term()
  def verify_fresh_marker(start, query, stop, token) do
    connection = start.()

    try do
      query.(connection, token)
    after
      stop.(connection)
    end
  end

  @spec cleanup(map(), map()) :: :ok | {:error, keyword()}
  def cleanup(%{created?: false, create_attempted?: false} = state, operations) do
    []
    |> run_step(:stop_admin, fn -> operations.stop.(state.admin_connection) end)
    |> cleanup_result()
  end

  def cleanup(state, operations) do
    with :ok <- validate_cleanup_target(state.database_name, state.token),
         {:ok, _uri} <- validate_admin_url(state.admin_url),
         {:ok, statements} <- cleanup_statements(state.database_name, state.token) do
      {errors, marker_allows_drop?} = marker_result(state, operations)

      errors =
        Enum.reduce(state.database_connections, errors, fn connection, acc ->
          run_step(acc, :stop, fn -> operations.stop.(connection) end)
        end)

      if marker_allows_drop? do
        finish_database_cleanup(state, operations, statements, errors)
      else
        errors
        |> run_step(:stop_admin, fn -> operations.stop.(state.admin_connection) end)
        |> cleanup_result()
      end
    else
      _unsafe -> {:error, safety: :unsafe_cleanup_target}
    end
  end

  defp finish_database_cleanup(state, operations, statements, errors) do
    {errors, terminate_admin} =
      ensure_admin(errors, :admin_terminate, state.admin_connection, state.admin_url, operations)

    errors =
      if terminate_admin do
        run_step(errors, :terminate, fn ->
          operations.terminate.(
            terminate_admin,
            statements.terminate_sql,
            statements.terminate_params
          )
        end)
      else
        errors
      end

    {errors, drop_admin} =
      ensure_admin(
        errors,
        :admin_drop,
        terminate_admin || state.admin_connection,
        state.admin_url,
        operations
      )

    errors =
      if drop_admin do
        run_step(errors, :drop, fn -> operations.drop.(drop_admin, statements.drop_sql) end)
      else
        errors
      end

    final_admin = drop_admin || terminate_admin

    errors =
      if final_admin,
        do: run_step(errors, :stop_admin, fn -> operations.stop.(final_admin) end),
        else: errors

    cleanup_result(errors)
  end

  defp ensure_admin(errors, step, connection, admin_url, operations) do
    case run_operation(fn -> operations.ensure_admin.(connection, admin_url) end) do
      {:ok, {:ok, admin_connection}} -> {errors, admin_connection}
      {:ok, {:error, reason}} -> {errors ++ [{step, reason}], nil}
      {:error, reason} -> {errors ++ [{step, reason}], nil}
    end
  end

  defp marker_result(%{marker_connection: nil}, _operations), do: {[], true}

  defp marker_result(state, operations) do
    case run_operation(fn -> operations.marker.(state.marker_connection, state.token) end) do
      {:ok, :ok} -> {[], true}
      {:ok, {:error, :marker_mismatch}} -> {[marker: :marker_mismatch], false}
      {:ok, {:error, reason}} -> {[marker: reason], true}
      {:ok, _other} -> {[marker: :marker_mismatch], false}
      {:error, reason} -> {[marker: reason], true}
    end
  end

  defp run_step(errors, step, operation) do
    case run_operation(operation) do
      {:ok, {:error, reason}} -> errors ++ [{step, reason}]
      {:ok, _result} -> errors
      {:error, reason} -> errors ++ [{step, reason}]
    end
  end

  defp run_operation(operation) do
    try do
      {:ok, operation.()}
    rescue
      exception -> {:error, {:raised, exception.__struct__}}
    catch
      kind, _reason -> {:error, kind}
    end
  end

  defp cleanup_result([]), do: :ok
  defp cleanup_result(errors), do: {:error, errors}
end
