defmodule SymphonyElixir.RepositoryBootstrap do
  @moduledoc """
  Materializes a newly-created profiled workspace at its freshly verified canonical revision.

  This is deliberately not a general hook: its repository, branch, and commit inputs come only
  from the approved execution context and authority receipt. Credentials remain call-local to the
  worker-aware command boundary.
  """

  alias SymphonyElixir.{GitCredentialEnvironment, GitHubCredentialResolver.Credential}
  alias SymphonyElixir.{ProjectExecutionContext, Workspace}

  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  @spec ensure(ProjectExecutionContext.t(), Workspace.preparation(), Credential.t(), map(), keyword()) ::
          :ok | {:error, :repository_bootstrap_failed}
  def ensure(%ProjectExecutionContext{}, %{created_now: false}, %Credential{}, _authority, _opts),
    do: :ok

  def ensure(
        %ProjectExecutionContext{} = context,
        %{created_now: true} = preparation,
        %Credential{} = credential,
        authority,
        opts
      )
      when is_map(authority) and is_list(opts) do
    result =
      with :ok <- validate_inputs(context, credential, authority),
           {:ok, runner} <- command_runner(preparation.path, context, opts),
           :ok <- execute(runner, ["init", "--initial-branch", context.canonical_branch], credential, opts),
           :ok <-
             execute(
               runner,
               ["remote", "add", "origin", canonical_url(context.repository)],
               credential,
               opts
             ),
           :ok <-
             execute(
               runner,
               [
                 "-c",
                 "http.followRedirects=false",
                 "fetch",
                 "--no-tags",
                 "--prune",
                 "origin",
                 "refs/heads/#{context.canonical_branch}:refs/remotes/origin/#{context.canonical_branch}"
               ],
               credential,
               opts
             ),
           :ok <- execute(runner, ["config", "--local", "core.autocrlf", "false"], credential, opts),
           :ok <-
             execute(
               runner,
               ["checkout", "-B", context.canonical_branch, String.downcase(authority.head_sha)],
               credential,
               opts
             ) do
        :ok
      else
        _failure -> {:error, :repository_bootstrap_failed}
      end

    if result == :ok do
      :ok
    else
      _ = cleanup(preparation, context, opts)
      {:error, :repository_bootstrap_failed}
    end
  rescue
    _exception ->
      _ = cleanup(preparation, context, opts)
      {:error, :repository_bootstrap_failed}
  end

  def ensure(_context, _preparation, _credential, _authority, _opts),
    do: {:error, :repository_bootstrap_failed}

  defp validate_inputs(context, credential, authority) do
    with true <- credential.credential_ref == context.credential_ref,
         true <- is_binary(credential.token) and byte_size(credential.token) > 0,
         true <- authority.default_branch == context.canonical_branch,
         true <- is_binary(authority.head_sha) and Regex.match?(@sha_pattern, authority.head_sha) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp command_runner(workspace, context, opts) do
    case {Keyword.get(opts, :command_runner), Keyword.get(opts, :worker_host)} do
      {runner, _host} when is_function(runner, 3) ->
        {:ok, runner}

      {nil, nil} ->
        {:ok,
         fn args, %Credential{} = credential, runtime ->
           with {:ok, environment} <- GitCredentialEnvironment.build(credential) do
             workspace_opts =
               runtime
               |> Keyword.take([:workspace_attestation, :private_home_capability])
               |> Keyword.put(:execution_context, context)
               |> Keyword.put(:env, environment)

             Workspace.run_git_command(workspace, args, nil, workspace_opts)
           end
         end}

      _remote_or_invalid ->
        {:error, :missing_worker_runner}
    end
  end

  defp execute(runner, args, credential, opts) do
    case runner.(args, credential, worker_runtime(opts)) do
      {:ok, output} when is_binary(output) -> :ok
      _failure -> {:error, :command_failed}
    end
  rescue
    _exception -> {:error, :command_failed}
  catch
    _kind, _reason -> {:error, :command_failed}
  end

  defp worker_runtime(opts) do
    Keyword.take(opts, [:worker_host, :workspace_attestation, :private_home_capability])
  end

  defp cleanup(preparation, context, opts) do
    case Keyword.get(opts, :cleanup) do
      cleanup when is_function(cleanup, 4) ->
        cleanup.(preparation.path, Keyword.get(opts, :worker_host), context, preparation.workspace_attestation)

      nil ->
        Workspace.rollback_failed_repository_bootstrap(
          context,
          Keyword.get(opts, :worker_host),
          preparation.workspace_attestation
        )

      _invalid ->
        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp canonical_url(repository), do: "https://github.com/#{repository}.git"
end
