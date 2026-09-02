defmodule SymphonyElixir.CodexExecutionInputs do
  @moduledoc "Resolves trusted, non-secret Codex launch inputs before isolation."

  alias SymphonyElixir.Linear.Issue

  @supported_models %{
    "model:gpt-5.4-mini" => "gpt-5.4-mini",
    "model:gpt-5.4" => "gpt-5.4",
    "model:gpt-5.5" => "gpt-5.5"
  }

  @spec resolve(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve(%Issue{} = issue, %{executable: executable, default_model: default_model})
      when is_binary(executable) and is_binary(default_model) do
    model_labels =
      issue
      |> Issue.label_names()
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.filter(&Map.has_key?(@supported_models, &1))
      |> Enum.uniq()
      |> Enum.sort()

    case model_labels do
      [] -> {:ok, environment(executable, default_model, "workflow default")}
      [label] -> {:ok, environment(executable, Map.fetch!(@supported_models, label), "Linear label #{label}")}
      labels -> {:error, {:multiple_codex_model_labels, labels}}
    end
  end

  defp environment(executable, model, source) do
    %{
      "CODEX_BIN" => executable,
      "CODEX_DEFAULT_MODEL" => model,
      "SYMPHONY_CODEX_MODEL_SOURCE" => source
    }
  end
end
