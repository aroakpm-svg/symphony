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
    case status() do
      {:ok, _status} -> :ok
      {:error, :admission_gate_invalid} = error -> error
    end
  end

  @doc "Returns true when admission is paused or gate configuration can no longer be trusted."
  @spec paused?() :: boolean()
  def paused? do
    case System.get_env(@environment) do
      nil -> false
      _path -> status() != {:ok, :open}
    end
  end

  @doc false
  @spec gate_entry_for_test(Path.t(), (Path.t() -> {:ok, File.Stat.t()} | {:error, term()})) ::
          :absent | :present | {:error, :admission_gate_invalid}
  def gate_entry_for_test(path, lstat_fun) when is_binary(path) and is_function(lstat_fun, 1),
    do: gate_entry(path, lstat_fun)

  defp status do
    with path when is_binary(path) and path != "" <- System.get_env(@environment),
         true <- Path.type(path) == :absolute,
         :ok <- SymphonyElixir.Workspace.validate_non_reparse_directory_for_worker(Path.dirname(path)),
         entry when entry in [:absent, :present] <- gate_entry(path, &File.lstat/1) do
      {:ok, if(entry == :present, do: :paused, else: :open)}
    else
      _invalid -> {:error, :admission_gate_invalid}
    end
  end

  defp gate_entry(path, lstat_fun) do
    case lstat_fun.(path) do
      {:error, :enoent} ->
        :absent

      {:ok, _stat} ->
        case SymphonyElixir.Workspace.validate_non_reparse_regular_file_for_worker(path) do
          :ok -> :present
          {:error, _reason} -> {:error, :admission_gate_invalid}
        end

      {:error, _reason} ->
        {:error, :admission_gate_invalid}
    end
  end
end
