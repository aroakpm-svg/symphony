defmodule SymphonyElixir.ClaimConnection do
  @moduledoc false

  @spec options(map()) :: {:ok, keyword()} | {:error, atom()}
  def options(settings) do
    with {:ok, database_options} <- database_options(settings.database_url),
         :ok <- validate_ca_file(settings.ca_cert_file) do
      {:ok,
       database_options ++
         [
           sync_connect: true,
           connect_timeout: 10_000,
           ssl: [
             verify: :verify_peer,
             cacertfile: String.to_charlist(settings.ca_cert_file),
             server_name_indication: String.to_charlist(database_options[:hostname]),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ]
         ]}
    end
  end

  @spec connect(map()) :: {:ok, Postgrex.conn()} | {:error, term()}
  def connect(settings), do: connect(settings, Postgrex)

  @doc false
  @spec connect(map(), module()) :: {:ok, term()} | {:error, term()}
  def connect(settings, adapter) do
    with {:ok, connection_options} <- options(settings),
         {:ok, connection} <- adapter.start_link(connection_options) do
      authenticated_connection(adapter, connection, settings)
    end
  end

  @doc false
  @spec authentication_result(term()) :: :ok | {:error, term()}
  def authentication_result({:ok, %Postgrex.Result{rows: [[_node_id, _instance_id, 3]], num_rows: 1}}), do: :ok
  def authentication_result({:ok, %Postgrex.Result{}}), do: {:error, :node_authentication_rejected}
  def authentication_result({:error, reason}), do: {:error, reason}

  defp authenticate(adapter, connection, settings) do
    sql = "select * from symphony_staging.authenticate_node($1::text::uuid, $2::text::uuid)"

    adapter
    |> apply(:query, [connection, sql, [settings.node_id, settings.node_instance_id], [timeout: 12_000]])
    |> authentication_result()
  end

  defp authenticated_connection(adapter, connection, settings) do
    case authenticate(adapter, connection, settings) do
      :ok ->
        {:ok, connection}

      {:error, reason} ->
        if Process.alive?(connection), do: GenServer.stop(connection)
        {:error, reason}
    end
  end

  defp database_options(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path, userinfo: userinfo}
      when scheme in ["postgres", "postgresql"] and is_binary(host) and host != "" and
             is_binary(path) and is_binary(userinfo) ->
        with {:ok, username, password} <- credentials(userinfo),
             {:ok, database} <- database_name(path) do
          {:ok, hostname: host, port: port || 5432, database: database, username: username, password: password}
        end

      _invalid ->
        {:error, :invalid_claim_database_url}
    end
  end

  defp database_options(_url), do: {:error, :invalid_claim_database_url}

  defp credentials(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] when username != "" and password != "" ->
        {:ok, URI.decode(username), URI.decode(password)}

      _invalid ->
        {:error, :invalid_claim_database_url}
    end
  end

  defp database_name(path) do
    case path |> String.trim_leading("/") |> URI.decode() do
      "" -> {:error, :invalid_claim_database_url}
      database -> {:ok, database}
    end
  end

  defp validate_ca_file(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, pem} <- File.read(path),
         entries when is_list(entries) <- :public_key.pem_decode(pem),
         true <- Enum.any?(entries, &certificate_entry?/1) do
      :ok
    else
      _invalid -> {:error, :invalid_claim_ca_cert_file}
    end
  end

  defp validate_ca_file(_path), do: {:error, :invalid_claim_ca_cert_file}

  defp certificate_entry?({:Certificate, _der, _cipher_info}), do: true
  defp certificate_entry?(_entry), do: false
end
