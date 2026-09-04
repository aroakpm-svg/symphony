defmodule SymphonyElixir.GitHubCredentialResolver do
  @moduledoc """
  Resolves an approved opaque GitHub credential reference through one trusted source.

  The resolved credential is intentionally an in-memory value for the current call stack. This
  boundary does not inspect ambient environment state or provision credentials.
  """

  @approved_refs ~w(github-central-brain github-project-management)

  defmodule Credential do
    @moduledoc false

    @enforce_keys [:credential_ref, :token]
    defstruct [:credential_ref, :token, :expires_at]

    @type t :: %__MODULE__{
            credential_ref: String.t(),
            token: binary(),
            expires_at: DateTime.t() | nil
          }
  end

  @type reason ::
          :credential_source_unconfigured
          | :credential_source_missing
          | :credential_source_conflict
          | :credential_reference_mismatch
          | :credential_expired
          | :credential_resolver_failed

  @spec resolve(String.t(), keyword()) :: {:ok, Credential.t()} | {:error, reason()}
  def resolve(ref, opts) when is_binary(ref) and is_list(opts) do
    with :ok <- approved_ref(ref),
         {:ok, source} <- source(opts),
         {:ok, result} <- invoke_source(source, ref),
         {:ok, credential} <- normalize(result, ref),
         :ok <- unexpired(credential) do
      {:ok, credential}
    end
  end

  def resolve(_ref, _opts), do: {:error, :credential_resolver_failed}

  defp approved_ref(ref) when ref in @approved_refs, do: :ok
  defp approved_ref(_ref), do: {:error, :credential_resolver_failed}

  defp source(opts) do
    case Keyword.get(opts, :credential_scope, :controller) do
      :worker -> configured_source(Keyword.get(opts, :credential_source))
      :controller -> controller_source(opts)
      _invalid -> {:error, :credential_resolver_failed}
    end
  end

  defp controller_source(opts) do
    option_configured? = Keyword.has_key?(opts, :credential_source)
    option_source = Keyword.get(opts, :credential_source)
    application_source = Application.get_env(:symphony_elixir, :github_credential_source)

    cond do
      option_configured? and not is_nil(application_source) ->
        {:error, :credential_source_conflict}

      option_configured? ->
        configured_source(option_source)

      not is_nil(application_source) ->
        configured_source(application_source)

      true ->
        {:error, :credential_source_unconfigured}
    end
  end

  defp configured_source(nil), do: {:error, :credential_source_unconfigured}

  defp configured_source(source) do
    if source_callback?(source) do
      {:ok, source}
    else
      {:error, :credential_resolver_failed}
    end
  end

  defp source_callback?(source) when is_function(source, 1), do: true

  defp source_callback?(source) when is_atom(source) do
    Code.ensure_loaded?(source) and function_exported?(source, :resolve, 1)
  end

  defp source_callback?(_source), do: false

  defp invoke_source(source, ref) do
    if is_function(source, 1), do: {:ok, source.(ref)}, else: {:ok, source.resolve(ref)}
  rescue
    _error -> {:error, :credential_resolver_failed}
  catch
    _kind, _reason -> {:error, :credential_resolver_failed}
  end

  defp normalize({:ok, %{credential_ref: source_ref}}, ref) when source_ref != ref,
    do: {:error, :credential_reference_mismatch}

  defp normalize({:ok, result}, ref) when is_map(result) and map_size(result) == 3 do
    case result do
      %{credential_ref: ^ref, token: token, expires_at: expires_at}
      when is_binary(token) and (is_nil(expires_at) or is_struct(expires_at, DateTime)) ->
        if valid_token?(token) do
          {:ok, %Credential{credential_ref: ref, token: token, expires_at: expires_at}}
        else
          {:error, :credential_resolver_failed}
        end

      _result ->
        {:error, :credential_resolver_failed}
    end
  end

  defp normalize({:error, :missing}, _ref), do: {:error, :credential_source_missing}
  defp normalize({:error, {:missing, _detail}}, _ref), do: {:error, :credential_source_missing}
  defp normalize({:error, :conflict}, _ref), do: {:error, :credential_source_conflict}
  defp normalize({:error, {:conflict, _detail}}, _ref), do: {:error, :credential_source_conflict}
  defp normalize({:error, :ambiguous}, _ref), do: {:error, :credential_source_conflict}
  defp normalize({:error, {:ambiguous, _detail}}, _ref), do: {:error, :credential_source_conflict}
  defp normalize(_result, _ref), do: {:error, :credential_resolver_failed}

  defp valid_token?(token) do
    byte_size(token) > 0 and
      :binary.match(token, <<0>>) == :nomatch and
      not Enum.all?(:binary.bin_to_list(token), &(&1 in [9, 10, 11, 12, 13, 32]))
  end

  defp unexpired(%Credential{expires_at: nil}), do: :ok

  defp unexpired(%Credential{expires_at: %DateTime{} = expires_at}) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :gt -> :ok
      _comparison -> {:error, :credential_expired}
    end
  rescue
    _error -> {:error, :credential_resolver_failed}
  catch
    _kind, _reason -> {:error, :credential_resolver_failed}
  end
end
