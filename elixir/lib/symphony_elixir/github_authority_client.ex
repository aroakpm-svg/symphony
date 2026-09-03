defmodule SymphonyElixir.GitHubAuthorityClient do
  @moduledoc """
  Verifies GitHub automation authority with a credential scoped to one approved profile.

  GitHub responses and credential material remain inside this boundary. Callers receive only the
  identity and repository authority evidence needed for a preflight receipt.
  """

  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @github_api "https://api.github.com"
  @approved_profiles [
    %{
      key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production"
    },
    %{
      key: "project-management",
      linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
      repository: "aroakpm-svg/aroak-project-management",
      canonical_branch: "main",
      workspace_namespace: "project-management",
      credential_ref: "github-project-management",
      environment: "local_non_production"
    }
  ]

  @type receipt :: %{
          actor: String.t(),
          repository: String.t(),
          pull?: boolean(),
          push?: boolean(),
          default_branch: String.t(),
          head_sha: String.t()
        }
  @type reason ::
          :github_unauthorized
          | :github_forbidden
          | :github_unexpected_actor
          | :github_repository_not_allowed
          | :github_pull_authority_missing
          | :github_push_authority_missing
          | :github_response_invalid
          | :github_authority_invalid
          | :github_unavailable

  @spec verify(map(), Credential.t(), keyword()) :: {:ok, receipt()} | {:error, reason()}
  def verify(profile, credential, opts) when is_map(profile) and is_list(opts) do
    with :ok <- approved_profile(profile),
         :ok <- credential_for_profile(credential, profile),
         {:ok, expected_actor} <- expected_actor(opts),
         {:ok, request_fun} <- request_fun(opts),
         headers <- authorization_headers(credential),
         {:ok, actor} <- fetch_actor(request_fun, headers),
         :ok <- expected_actor(actor, expected_actor),
         {:ok, repository} <- fetch_repository(request_fun, headers, profile),
         :ok <- pull_authority(repository),
         :ok <- push_authority(repository),
         {:ok, head_sha} <- fetch_head_sha(request_fun, headers, profile, repository.default_branch) do
      {:ok,
       %{
         actor: actor,
         repository: profile.repository,
         pull?: repository.pull?,
         push?: repository.push?,
         default_branch: repository.default_branch,
         head_sha: head_sha
       }}
    end
  end

  def verify(_profile, _credential, _opts), do: {:error, :github_authority_invalid}

  defp approved_profile(profile) do
    if profile in @approved_profiles,
      do: :ok,
      else: {:error, :github_repository_not_allowed}
  end

  defp credential_for_profile(
         %Credential{credential_ref: credential_ref, token: token},
         %{credential_ref: credential_ref}
       )
       when is_binary(token) do
    if valid_token?(token), do: :ok, else: {:error, :github_authority_invalid}
  end

  defp credential_for_profile(_credential, _profile), do: {:error, :github_authority_invalid}

  defp valid_token?(token) do
    byte_size(token) > 0 and
      :binary.match(token, <<0>>) == :nomatch and
      not Enum.all?(:binary.bin_to_list(token), &(&1 in [9, 10, 11, 12, 13, 32]))
  end

  defp expected_actor(opts) do
    case Keyword.get(opts, :expected_actor) do
      actor when is_binary(actor) ->
        if valid_text?(actor), do: {:ok, actor}, else: {:error, :github_authority_invalid}

      _actor ->
        {:error, :github_authority_invalid}
    end
  end

  defp request_fun(opts) do
    case Keyword.get(opts, :request_fun, &Req.request/1) do
      request_fun when is_function(request_fun, 1) -> {:ok, request_fun}
      _request_fun -> {:error, :github_authority_invalid}
    end
  end

  defp authorization_headers(%Credential{token: token}) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"}
    ]
  end

  defp fetch_actor(request_fun, headers) do
    with {:ok, %{"login" => actor}} <- github_get(request_fun, user_url(), headers),
         true <- valid_text?(actor) do
      {:ok, actor}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp expected_actor(actor, expected_actor) when actor == expected_actor, do: :ok
  defp expected_actor(_actor, _expected_actor), do: {:error, :github_unexpected_actor}

  defp fetch_repository(request_fun, headers, profile) do
    with {:ok,
          %{
            "full_name" => repository,
            "default_branch" => branch,
            "permissions" => %{"pull" => pull?, "push" => push?}
          }} <- github_get(request_fun, repository_url(profile), headers),
         true <- repository == profile.repository and branch == profile.canonical_branch,
         true <- valid_text?(branch) and is_boolean(pull?) and is_boolean(push?) do
      {:ok, %{default_branch: branch, pull?: pull?, push?: push?}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :github_repository_not_allowed}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp pull_authority(%{pull?: true}), do: :ok
  defp pull_authority(_repository), do: {:error, :github_pull_authority_missing}

  defp push_authority(%{push?: true}), do: :ok
  defp push_authority(_repository), do: {:error, :github_push_authority_missing}

  defp fetch_head_sha(request_fun, headers, profile, branch) do
    with {:ok, %{"ref" => ref, "object" => %{"sha" => sha}}} <-
           github_get(request_fun, head_url(profile, branch), headers),
         true <- ref == "refs/heads/" <> branch,
         true <- valid_text?(sha) do
      {:ok, sha}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :github_response_invalid}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp github_get(request_fun, url, headers) do
    request_fun
    |> invoke_request(method: :get, url: url, headers: headers)
    |> classify_response()
  end

  defp invoke_request(request_fun, request) do
    request_fun.(request)
  rescue
    _exception -> {:error, :github_unavailable}
  catch
    _kind, _reason -> {:error, :github_unavailable}
  end

  defp classify_response({:ok, %{status: 200, body: body}}) when is_map(body), do: {:ok, body}
  defp classify_response({:ok, %{status: 401}}), do: {:error, :github_unauthorized}
  defp classify_response({:ok, %{status: 403}}), do: {:error, :github_forbidden}
  defp classify_response({:ok, %{status: status}}) when is_integer(status), do: {:error, :github_unavailable}
  defp classify_response({:error, _reason}), do: {:error, :github_unavailable}
  defp classify_response(_response), do: {:error, :github_response_invalid}

  defp user_url, do: @github_api <> "/user"

  defp repository_url(%{repository: repository}), do: @github_api <> "/repos/" <> repository

  defp head_url(%{repository: repository}, branch) do
    @github_api <> "/repos/" <> repository <> "/git/ref/heads/" <> branch
  end

  defp valid_text?(value) when is_binary(value), do: byte_size(String.trim(value)) > 0
  defp valid_text?(_value), do: false
end
