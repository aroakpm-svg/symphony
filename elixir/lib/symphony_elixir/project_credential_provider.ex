defmodule SymphonyElixir.ProjectCredentialProvider do
  @moduledoc """
  Resolves one approved project credential reference into a subprocess-only environment.

  The production default deliberately fails closed. ARO-195/196 owns the approved host
  adapter that can be injected as `:credential_provider`.
  """

  alias SymphonyElixir.ProjectExecutionContext

  @credential_environment_keys MapSet.new([
                                 "GH_TOKEN",
                                 "GITHUB_TOKEN",
                                 "GIT_ASKPASS",
                                 "SSH_ASKPASS",
                                 "GIT_SSH_COMMAND",
                                 "SSH_AUTH_SOCK",
                                 "SSH_AGENT_PID",
                                 "GIT_CONFIG_PARAMETERS",
                                 "GIT_CONFIG_COUNT",
                                 "OPENAI_API_KEY"
                               ])

  @type environment :: %{optional(String.t()) => String.t()}
  @type reason ::
          :credential_provider_unconfigured
          | :credential_not_found
          | :credential_ambiguous
          | :credential_reference_mismatch
          | :invalid_credential_environment
          | :credential_provider_failed

  @spec resolve(ProjectExecutionContext.t(), keyword()) ::
          {:ok, environment()} | {:error, reason()}
  def resolve(%ProjectExecutionContext{credential_ref: credential_ref}, opts)
      when is_binary(credential_ref) and is_list(opts) do
    case Keyword.get(opts, :credential_provider) do
      provider when is_function(provider, 1) -> resolve_with(provider, credential_ref)
      _provider -> {:error, :credential_provider_unconfigured}
    end
  end

  def resolve(_context, _opts), do: {:error, :credential_provider_failed}

  defp resolve_with(provider, credential_ref) do
    provider.(credential_ref)
    |> normalize_result(credential_ref)
  rescue
    _error -> {:error, :credential_provider_failed}
  catch
    _kind, _reason -> {:error, :credential_provider_failed}
  end

  defp normalize_result({:ok, {credential_ref, environment}}, credential_ref) do
    validate_environment(environment)
  end

  defp normalize_result({:ok, {_other_ref, _environment}}, _credential_ref),
    do: {:error, :credential_reference_mismatch}

  defp normalize_result({:error, {:missing, _detail}}, _credential_ref),
    do: {:error, :credential_not_found}

  defp normalize_result({:error, :missing}, _credential_ref),
    do: {:error, :credential_not_found}

  defp normalize_result({:error, {:ambiguous, _detail}}, _credential_ref),
    do: {:error, :credential_ambiguous}

  defp normalize_result({:error, :ambiguous}, _credential_ref),
    do: {:error, :credential_ambiguous}

  defp normalize_result(_result, _credential_ref), do: {:error, :credential_provider_failed}

  defp validate_environment(environment) when is_map(environment) do
    if Enum.all?(environment, &valid_environment_entry?/1) do
      {:ok, environment}
    else
      {:error, :invalid_credential_environment}
    end
  end

  defp validate_environment(_environment), do: {:error, :invalid_credential_environment}

  defp valid_environment_entry?({key, value}) when is_binary(key) and is_binary(value) do
    allowed_credential_key?(key) and not String.contains?(value, <<0>>)
  end

  defp valid_environment_entry?(_entry), do: false

  defp allowed_credential_key?(key) do
    MapSet.member?(@credential_environment_keys, key) or
      Regex.match?(~r/^GIT_CONFIG_(?:KEY|VALUE)_\d+$/, key)
  end
end
