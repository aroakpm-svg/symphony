defmodule SymphonyElixir.ProjectCredentialProvider do
  @moduledoc """
  Resolves a project credential through the canonical trusted source and, after validation by the
  caller, derives the minimal immediate child-process environment.
  """

  alias SymphonyElixir.GitHubCredentialResolver
  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.ProjectExecutionContext

  @type environment :: %{optional(String.t()) => binary()}

  @spec resolve(ProjectExecutionContext.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, GitHubCredentialResolver.reason()}
  def resolve(%ProjectExecutionContext{credential_ref: credential_ref}, opts)
      when is_binary(credential_ref) and is_list(opts) do
    GitHubCredentialResolver.resolve(credential_ref, opts)
  end

  def resolve(_context, _opts), do: {:error, :credential_resolver_failed}

  @spec environment(Credential.t()) ::
          {:ok, environment()} | {:error, :credential_resolver_failed}
  def environment(%Credential{token: token}) when is_binary(token) and byte_size(token) > 0 do
    {:ok, %{"GH_TOKEN" => token}}
  end

  def environment(_credential), do: {:error, :credential_resolver_failed}
end
