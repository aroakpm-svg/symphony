defmodule SymphonyElixir.GitPreflightCommand do
  @moduledoc """
  Runs bootstrap and checkout probes with one secret-safe failure contract.

  Only a remote operation's execution failure is retryable. Local failures, malformed
  callback results and exceptions cannot become transport evidence. Remote retries must
  pass fresh authority checks; output text is never used to infer authorization.
  """

  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @spec run(function(), [String.t()], Credential.t(), keyword(), :local | :remote) ::
          {:ok, String.t()} | {:error, :command_failed | :github_unavailable}
  def run(runner, args, credential, runtime, operation) do
    case runner.(args, credential, runtime) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      {:error, reason} when operation == :remote -> remote_failure(reason)
      _failure -> {:error, :command_failed}
    end
  rescue
    _exception -> {:error, :command_failed}
  catch
    _kind, _reason -> {:error, :command_failed}
  end

  defp remote_failure({:git_command_failed, _command, _status, _output}), do: {:error, :github_unavailable}
  defp remote_failure({:git_command_failed, _command, _reason}), do: {:error, :github_unavailable}
  defp remote_failure({:workspace_hook_timeout, _command, _timeout}), do: {:error, :github_unavailable}
  defp remote_failure(:timeout), do: {:error, :github_unavailable}
  defp remote_failure(_reason), do: {:error, :command_failed}
end
