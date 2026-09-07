defmodule SymphonyElixir.GitHubAppCredentialSource do
  @moduledoc """
  Mints one call-local GitHub App installation credential for an approved project reference.

  Configuration and private-key material are read for every invocation and are never cached.
  """

  @api "https://api.github.com"
  @repositories %{
    "github-central-brain" => "aroak-central-brain",
    "github-project-management" => "aroak-project-management"
  }

  @type result ::
          {:ok, %{credential_ref: String.t(), token: binary(), expires_at: DateTime.t()}}
          | {:error, :missing | :unavailable | :failed}

  @doc "Enables this source from complete node-local runtime configuration."
  @spec configure() :: :ok | {:error, :github_app_configuration_invalid}
  def configure do
    actor = System.get_env("SYMPHONY_GITHUB_APP_EXPECTED_ACTOR")

    with {:ok, opts} <- runtime_options(),
         true <- is_binary(actor) and String.trim(actor) != "" and String.ends_with?(actor, "[bot]"),
         {:ok, _app_id} <- positive_identifier(opts[:app_id]),
         {:ok, _installation_id} <- positive_identifier(opts[:installation_id]),
         {:ok, _key} <- private_key(opts[:private_key_path]),
         :ok <- compatible_source(),
         {:ok, orchestrator_opts} <- compatible_orchestrator_options(actor) do
      Application.put_env(:symphony_elixir, :github_credential_source, __MODULE__)
      Application.put_env(:symphony_elixir, :orchestrator_opts, Keyword.put(orchestrator_opts, :expected_actor, actor))
      :ok
    else
      _invalid -> {:error, :github_app_configuration_invalid}
    end
  end

  @spec resolve(String.t()) :: result()
  def resolve(ref) do
    with {:ok, opts} <- runtime_options() do
      resolve(ref, opts)
    end
  end

  @doc false
  @spec resolve(String.t(), keyword()) :: result()
  def resolve(ref, opts) when is_binary(ref) and is_list(opts) do
    with {:ok, repository} <- Map.fetch(@repositories, ref),
         {:ok, app_id} <- positive_identifier(opts[:app_id]),
         {:ok, installation_id} <- positive_identifier(opts[:installation_id]),
         {:ok, now} <- timestamp(opts[:now] || DateTime.utc_now()),
         {:ok, key} <- private_key(opts[:private_key_path]),
         {:ok, jwt} <- signed_jwt(app_id, now, key),
         {:ok, token, expires_at} <- mint(installation_id, repository, jwt, opts[:request_fun] || (&Req.request/1)),
         :gt <- DateTime.compare(expires_at, now) do
      {:ok, %{credential_ref: ref, token: token, expires_at: expires_at}}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _failure -> {:error, :failed}
    end
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  def resolve(_ref, _opts), do: {:error, :failed}

  defp runtime_options do
    values =
      [
        app_id: System.get_env("SYMPHONY_GITHUB_APP_ID"),
        installation_id: System.get_env("SYMPHONY_GITHUB_APP_INSTALLATION_ID"),
        private_key_path: System.get_env("SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE")
      ]

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and String.trim(value) != "" end),
      do: {:ok, values},
      else: {:error, :missing}
  end

  defp compatible_source do
    case Application.get_env(:symphony_elixir, :github_credential_source) do
      nil -> :ok
      __MODULE__ -> :ok
      _other -> {:error, :conflict}
    end
  end

  defp compatible_orchestrator_options(actor) do
    case Application.get_env(:symphony_elixir, :orchestrator_opts, []) do
      opts when is_list(opts) and opts != [] ->
        if Keyword.keyword?(opts), do: compatible_expected_actor(opts, actor), else: {:error, :conflict}

      [] ->
        {:ok, []}

      _invalid ->
        {:error, :conflict}
    end
  end

  defp compatible_expected_actor(opts, actor) do
    case Keyword.get(opts, :expected_actor) do
      nil -> {:ok, opts}
      ^actor -> {:ok, opts}
      _other -> {:error, :conflict}
    end
  end

  defp positive_identifier(value) when is_integer(value) and value > 0, do: {:ok, Integer.to_string(value)}

  defp positive_identifier(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, value}
      _invalid -> {:error, :invalid}
    end
  end

  defp positive_identifier(_value), do: {:error, :invalid}

  defp timestamp(%DateTime{} = value), do: {:ok, value}
  defp timestamp(_value), do: {:error, :invalid}

  defp private_key(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         :ok <- validate_parent_directories(Path.dirname(path)),
         :ok <- SymphonyElixir.Workspace.validate_non_reparse_regular_file_for_worker(path),
         {:ok, pem} <- File.read(path),
         [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         true <- elem(key, 0) == :RSAPrivateKey do
      {:ok, key}
    else
      _invalid -> {:error, :invalid}
    end
  rescue
    _error -> {:error, :invalid}
  end

  defp private_key(_path), do: {:error, :invalid}

  defp validate_parent_directories(path) do
    parent = Path.dirname(path)

    with :ok <- SymphonyElixir.Workspace.validate_non_reparse_directory_for_worker(path) do
      if parent == path, do: :ok, else: validate_parent_directories(parent)
    end
  end

  defp signed_jwt(app_id, now, key) do
    issued_at = DateTime.to_unix(now) - 60
    expires_at = issued_at + 540
    header = base64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))
    claims = base64url(Jason.encode!(%{"iat" => issued_at, "exp" => expires_at, "iss" => app_id}))
    signing_input = header <> "." <> claims
    signature = :public_key.sign(signing_input, :sha256, key)
    {:ok, signing_input <> "." <> base64url(signature)}
  end

  defp mint(installation_id, repository, jwt, request_fun) when is_function(request_fun, 1) do
    response =
      request_fun.(
        method: :post,
        url: @api <> "/app/installations/" <> installation_id <> "/access_tokens",
        headers: [
          {"authorization", "Bearer " <> jwt},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "symphony-github-app-source"}
        ],
        json: %{repositories: [repository]},
        redirect: false,
        receive_timeout: 8_000
      )

    case response do
      {:ok, %{status: 201, body: %{"token" => token, "expires_at" => expires_at}}}
      when is_binary(token) and byte_size(token) > 0 ->
        with false <- Enum.all?(:binary.bin_to_list(token), &(&1 in [9, 10, 11, 12, 13, 32])),
             :nomatch <- :binary.match(token, <<0>>),
             {:ok, parsed, 0} <- DateTime.from_iso8601(expires_at) do
          {:ok, token, parsed}
        end

      {:ok, %{status: status}} when status == 408 or status == 429 or status in 500..599 ->
        {:error, :unavailable}

      {:error, _transport_reason} ->
        {:error, :unavailable}

      _failure ->
        {:error, :invalid}
    end
  end

  defp mint(_installation_id, _repository, _jwt, _request_fun), do: {:error, :invalid}

  defp base64url(value), do: Base.url_encode64(value, padding: false)
end
