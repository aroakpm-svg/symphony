defmodule Mix.Tasks.Review.ControlPlane do
  use Mix.Task

  alias SymphonyElixir.{GitHubReviewClient, ReviewControlPlane, ReviewTargetRegistry}

  @shortdoc "Run the trusted multi-target Review Convergence Gate"

  @moduledoc """
  Evaluates the explicitly allowlisted targets from `SYMPHONY_REVIEW_TARGETS`.

  Run this task only from a separately trusted Symphony runtime checkout. The
  target repository is data supplied by the runtime environment; the target
  pull-request checkout is never loaded as the reviewer implementation.

      SYMPHONY_REVIEW_TARGETS='[{"repository":"owner/name","pull_request_number":1,"head_sha":"...","required_checks":[{"name":"ci","app_slug":"github-actions","app_id":15368}]}]' \\
        mix review.control_plane
  """

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    {_opts, _argv, invalid} = OptionParser.parse(args, strict: [])

    case invalid do
      [] -> run_control_plane()
      _invalid -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end
  end

  defp run_control_plane do
    with {:ok, targets} <- ReviewTargetRegistry.from_env(),
         # The target head is immutable and is also the status revocation address,
         # so a fresh CLI state cannot leave an unverifiable success green.
         # This status-only slice does not track fix rounds.
         {:ok, _state, outcomes} <-
           ReviewControlPlane.run(targets, %{}, GitHubReviewClient, 3),
         :ok <- print_outcomes(outcomes),
         :ok <- ensure_all_targets_converged(outcomes) do
      :ok
    else
      {:error, reason} -> Mix.raise("Review control plane blocked: #{inspect(reason)}")
    end
  end

  defp print_outcomes(outcomes) do
    Enum.each(outcomes, fn outcome -> Mix.shell().info(Jason.encode!(outcome)) end)
    :ok
  end

  defp ensure_all_targets_converged(outcomes) do
    if Enum.all?(outcomes, &(&1.status == :success)) do
      :ok
    else
      {:error, {:targets_not_converged, outcomes}}
    end
  end
end
