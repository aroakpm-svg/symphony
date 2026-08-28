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
         drop_sql: ~s(drop database "#{database_name}")
       }}
    end
  end
end
