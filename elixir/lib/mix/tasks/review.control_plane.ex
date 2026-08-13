defmodule Mix.Tasks.Review.ControlPlane do
  use Mix.Task

  alias SymphonyElixir.{GitHubReviewClient, ReviewControlPlane, ReviewTargetRegistry}

  @shortdoc "Run the trusted multi-target Review Convergence Gate"

  @moduledoc """
  Evaluates the explicitly allowlisted targets from `SYMPHONY_REVIEW_TARGETS`.

  Run this task only from a separately trusted Symphony runtime checkout. The
  target repository is data supplied by the runtime environment; the target
  pull-request checkout is never loaded as the reviewer implementation.

      SYMPHONY_REVIEW_TARGETS='[{"repository":"owner/name","pull_request_number":1,"head_sha":"..."}]' \\
        mix review.control_plane
  """

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [max_fix_rounds: :integer])

    case invalid do
      [] -> run_control_plane(opts)
      _invalid -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end
  end

  defp run_control_plane(opts) do
    max_fix_rounds = Keyword.get(opts, :max_fix_rounds, 3)

    with {:ok, targets} <- ReviewTargetRegistry.from_env(),
         {:ok, _state, outcomes} <-
           ReviewControlPlane.run(targets, %{}, GitHubReviewClient, max_fix_rounds),
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
