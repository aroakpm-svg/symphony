defmodule SymphonyElixir.ProjectRepoPreflight do
  @moduledoc """
  Credential-scoped readiness check for explicitly approved project repositories.

  A fresh canonical credential is resolved and consumed entirely within this call. Only bounded
  authority and quality-contract evidence is returned to the pre-claim orchestrator path.
  """

  alias SymphonyElixir.{GitHubAuthorityClient, GitHubCredentialResolver, ProjectProfiles}
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @profile_fields MapSet.new(~w(key linear_project_id repository canonical_branch workspace_namespace credential_ref environment)a)
  @required_scripts_by_profile %{
    "central-brain" => ["typecheck", "build", "test"],
    "project-management" => ["typecheck", "build", "db:test"]
  }
  @github_api "https://api.github.com"
  @timeout_ms 10_000
  @blocker_next_steps %{
    credential_source_unconfigured: "Configure the one trusted credential source for this runtime.",
    credential_source_missing: "Configure the one trusted credential source for this runtime.",
    credential_source_conflict: "Remove competing credential sources and retain only the canonical source.",
    credential_reference_mismatch: "Renew a credential bound to the approved project reference.",
    credential_expired: "Renew a credential bound to the approved project reference.",
    github_unexpected_actor: "Configure the expected dedicated automation identity.",
    github_pull_authority_missing: "Grant the approved repository read and push authority to the automation identity.",
    github_push_authority_missing: "Grant the approved repository read and push authority to the automation identity.",
    github_unauthorized: "Renew or correct the canonical GitHub installation authority.",
    github_forbidden: "Renew or correct the canonical GitHub installation authority.",
    github_repository_not_allowed: "Use the approved project mapping and a token restricted to that repository.",
    github_unavailable: "Retry the credential-scoped GitHub preflight.",
    github_response_invalid: "Retry the credential-scoped GitHub preflight."
  }

  @type receipt :: %{
          project: String.t(),
          repository: String.t(),
          actor: String.t(),
          pull?: boolean(),
          push?: boolean(),
          default_branch: String.t(),
          head_sha: String.t(),
          required_scripts: [String.t()]
        }
  @type blocker :: %{code: atom(), detail: term(), next_step: String.t()}

  @spec check(ProjectProfiles.profile(), keyword()) :: {:ok, receipt()} | {:blocked, blocker()}
  def check(profile, opts \\ []) do
    if is_list(opts), do: bounded_check(profile, opts), else: invalid_profile(profile)
  end

  defp bounded_check(profile, opts) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(caller, {tag, supervise_check(caller, profile, opts)}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        blocker_for(:github_unavailable)
    end
  end

  # The supervisor owns the deadline even if the scheduler dies during a callback.
  # It never invokes credential-bearing code itself and only forwards sanitized results.
  defp supervise_check(caller, profile, opts) do
    owner_monitor = Process.monitor(caller)
    supervisor = self()
    tag = make_ref()
    {worker, monitor} = spawn_monitor(fn -> send(supervisor, {tag, safe_check(profile, opts)}) end)

    result =
      receive do
        {^tag, result} -> result
        {:DOWN, ^owner_monitor, :process, ^caller, _reason} -> blocker_for(:github_unavailable)
        {:DOWN, ^monitor, :process, ^worker, _reason} -> blocker_for(:github_unavailable)
      after
        preflight_timeout(opts) -> blocker_for(:github_unavailable)
      end

    # A fresh monitor also works if the result branch already consumed DOWN.
    termination = Process.monitor(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^termination, :process, ^worker, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])
    Process.demonitor(owner_monitor, [:flush])
    result
  end

  defp safe_check(profile, opts) do
    check_profile(profile, opts)
  rescue
    _exception -> blocker_for(:github_unavailable)
  catch
    _kind, _reason -> blocker_for(:github_unavailable)
  end

  defp preflight_timeout(opts) do
    case Keyword.get(opts, :timeout, @timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= @timeout_ms -> timeout
      _invalid -> @timeout_ms
    end
  end

  defp check_profile(profile, opts) do
    with {:ok, _project, mapping} <- mapping_from_profile(profile),
         {:ok, credential} <- GitHubCredentialResolver.resolve(mapping.credential_ref, opts) do
      check_credential(profile, credential, opts)
    else
      :error -> invalid_profile(profile)
      {:error, reason} -> blocker_for(reason)
    end
  end

  @doc "Validates fresh authority and the quality contract at that exact head using one call-local credential."
  @spec check_credential(ProjectProfiles.profile(), Credential.t(), keyword()) ::
          {:ok, receipt()} | {:blocked, blocker()}
  def check_credential(profile, credential, opts) do
    with {:ok, project, mapping} <- mapping_from_profile(profile),
         {:ok, authority} <- GitHubAuthorityClient.verify(profile, credential, opts),
         {:ok, scripts} <- package_scripts(mapping, authority.head_sha, credential, opts),
         :ok <- verify_required_scripts(mapping, scripts) do
      {:ok, receipt(project, mapping, authority)}
    else
      :error ->
        blocked(
          :project_mapping_missing,
          profile_key(profile),
          "Pass a complete approved project profile."
        )

      {:error, reason} ->
        blocker_for(reason)

      {:blocked, _blocker} = blocked ->
        blocked
    end
  end

  defp invalid_profile(profile) do
    blocked(
      :project_mapping_missing,
      profile_key(profile),
      "Pass a complete approved project profile."
    )
  end

  defp mapping_from_profile(%{} = profile) do
    with true <- MapSet.equal?(MapSet.new(Map.keys(profile)), @profile_fields),
         %{
           key: key,
           repository: repository,
           canonical_branch: canonical_branch,
           credential_ref: credential_ref
         } <- profile,
         true <- Enum.all?([key, repository, canonical_branch, credential_ref], &is_binary/1),
         {:ok, required_scripts} <- Map.fetch(@required_scripts_by_profile, key) do
      {:ok, key,
       %{
         repository: repository,
         default_branch: canonical_branch,
         credential_ref: credential_ref,
         required_scripts: required_scripts
       }}
    else
      _invalid -> :error
    end
  end

  defp mapping_from_profile(_profile), do: :error

  defp profile_key(%{key: key}) when is_binary(key), do: key
  defp profile_key(_profile), do: nil

  defp package_scripts(mapping, head_sha, %Credential{token: token}, opts) do
    with {:ok, request_fun} <- request_fun(opts),
         {:ok, body} <- package_request(request_fun, mapping, head_sha, token),
         {:ok, decoded} <- decode_package(body),
         %{"scripts" => scripts} when is_map(scripts) <- decoded do
      {:ok, scripts}
    else
      {:error, :github_response_invalid} ->
        blocked(
          :required_check_contract_invalid,
          nil,
          "Restore a valid package.json scripts contract at the verified head."
        )

      {:error, :required_check_contract_unreadable} ->
        blocked(
          :required_check_contract_unreadable,
          nil,
          "Ensure package.json is readable at the verified head."
        )

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        blocked(
          :required_check_contract_invalid,
          nil,
          "Restore a valid package.json scripts contract at the verified head."
        )
    end
  end

  defp request_fun(opts) do
    case Keyword.get(opts, :request_fun, &Req.request/1) do
      request_fun when is_function(request_fun, 1) -> {:ok, request_fun}
      _request_fun -> {:error, :github_authority_invalid}
    end
  end

  defp package_request(request_fun, mapping, head_sha, token) do
    request = [
      method: :get,
      url: @github_api <> "/repos/" <> mapping.repository <> "/contents/package.json?ref=" <> head_sha,
      headers: [
        {"authorization", "Bearer " <> token},
        {"accept", "application/vnd.github.raw+json"}
      ],
      redirect: false
    ]

    request_fun
    |> invoke_request(request)
    |> classify_package_response()
  end

  defp invoke_request(request_fun, request) do
    request_fun.(request)
  rescue
    _exception -> {:error, :github_unavailable}
  catch
    _kind, _reason -> {:error, :github_unavailable}
  end

  defp classify_package_response({:ok, %{status: 200, body: body}})
       when is_map(body) or is_binary(body),
       do: {:ok, body}

  defp classify_package_response({:ok, %{status: 401}}), do: {:error, :github_unauthorized}

  defp classify_package_response({:ok, %{status: 403} = response}),
    do: SymphonyElixir.GitHubResponse.classify_forbidden(response)

  defp classify_package_response({:ok, %{status: 404}}),
    do: {:error, :required_check_contract_unreadable}

  defp classify_package_response({:ok, %{status: _status}}), do: {:error, :github_unavailable}
  defp classify_package_response({:error, _reason}), do: {:error, :github_unavailable}
  defp classify_package_response(_response), do: {:error, :github_response_invalid}

  defp decode_package(body) when is_map(body), do: {:ok, body}

  defp decode_package(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp verify_required_scripts(mapping, scripts) do
    missing =
      Enum.reject(mapping.required_scripts, fn name ->
        case Map.get(scripts, name) do
          command when is_binary(command) -> String.trim(command) != ""
          _other -> false
        end
      end)

    if missing == [] do
      :ok
    else
      blocked(
        :required_check_contract_missing,
        missing,
        "Add the missing quality scripts to package.json before enabling runtime pickup."
      )
    end
  end

  defp receipt(project, mapping, authority) do
    %{
      project: project,
      repository: authority.repository,
      actor: authority.actor,
      pull?: authority.pull?,
      push?: authority.push?,
      default_branch: authority.default_branch,
      head_sha: authority.head_sha,
      required_scripts: mapping.required_scripts
    }
  end

  defp blocker_for(reason) do
    next_step =
      Map.get(
        @blocker_next_steps,
        reason,
        "Correct the trusted GitHub credential preflight configuration."
      )

    blocked(reason, nil, next_step)
  end

  defp blocked(code, detail, next_step),
    do: {:blocked, %{code: code, detail: detail, next_step: next_step}}
end
