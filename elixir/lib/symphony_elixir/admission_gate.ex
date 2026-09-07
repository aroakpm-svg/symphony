defmodule SymphonyElixir.AdmissionGate do
  @moduledoc """
  Provides a node-local, fail-closed file gate for pausing new issue admission.

  Existing workers continue running while polling, retries, claims, and post-claim dispatch observe
  the same gate before starting new work.
  """

  @environment "SYMPHONY_ADMISSION_PAUSE_FILE"

  @doc "Validates the configured gate path without creating or removing the gate."
  @spec validate_configuration() :: :ok | {:error, :admission_gate_invalid}
  def validate_configuration do
    with path when is_binary(path) and path != "" <- System.get_env(@environment),
         true <- Path.type(path) == :absolute,
         :ok <- SymphonyElixir.Workspace.validate_non_reparse_directory_for_worker(Path.dirname(path)),
         :ok <- validate_existing_gate(path) do
      :ok
    else
      _invalid -> {:error, :admission_gate_invalid}
    end
  end

  @doc "Returns true when admission is paused or gate configuration can no longer be trusted."
  @spec paused?() :: boolean()
  def paused? do
    case System.get_env(@environment) do
      nil -> false
      path -> validate_configuration() != :ok or File.exists?(path)
    end
  end

  defp validate_existing_gate(path) do
    if File.exists?(path) do
      SymphonyElixir.Workspace.validate_non_reparse_regular_file_for_worker(path)
    else
      :ok
    end
  end
end
