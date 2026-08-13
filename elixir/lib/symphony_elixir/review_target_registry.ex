defmodule SymphonyElixir.ReviewTargetRegistry do
  @moduledoc """
  Loads the explicitly allowlisted review targets for a trusted runtime.

  The registry is intentionally supplied through an environment variable. It
  is not read from a target repository's `WORKFLOW.md`, so a pull request under
  review cannot add itself to the reviewer's allowlist or change its status
  destination.
  """

  alias SymphonyElixir.ReviewTarget

  @env "SYMPHONY_REVIEW_TARGETS"

  @spec from_env() :: {:ok, [ReviewTarget.t()]} | {:error, term()}
  def from_env do
    case System.get_env(@env) do
      value when is_binary(value) and value != "" ->
        case Jason.decode(value) do
          {:ok, decoded} -> parse(decoded)
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      _missing ->
        {:error, {:missing_environment, @env}}
    end
  end

  @spec parse(term()) :: {:ok, [ReviewTarget.t()]} | {:error, term()}
  def parse(targets) when is_list(targets), do: ReviewTarget.validate_all(targets)
  def parse(_targets), do: {:error, :review_target_allowlist_invalid}
end
