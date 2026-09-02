defmodule SymphonyElixir.CodexExecutionInputsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CodexExecutionInputs

  test "resolves the executable and model from trusted config and fetched issue labels" do
    issue = %Issue{labels: ["team:platform", "model:gpt-5.5"]}

    assert {:ok, environment} =
             CodexExecutionInputs.resolve(issue, %{executable: "/opt/codex/bin/codex", default_model: "gpt-5.4-mini"})

    assert environment == %{
             "CODEX_BIN" => "/opt/codex/bin/codex",
             "CODEX_DEFAULT_MODEL" => "gpt-5.5",
             "SYMPHONY_CODEX_MODEL_SOURCE" => "Linear label model:gpt-5.5"
           }
  end

  test "uses the configured default without a model label" do
    assert {:ok, environment} =
             CodexExecutionInputs.resolve(%Issue{labels: []}, %{
               executable: "C:/tools/codex.exe",
               default_model: "gpt-5.4"
             })

    assert environment["CODEX_DEFAULT_MODEL"] == "gpt-5.4"
    assert environment["SYMPHONY_CODEX_MODEL_SOURCE"] == "workflow default"
  end

  test "rejects ambiguous supported model labels before launching Codex" do
    issue = %Issue{labels: ["model:gpt-5.4", "model:gpt-5.5"]}

    assert {:error, {:multiple_codex_model_labels, ["model:gpt-5.4", "model:gpt-5.5"]}} =
             CodexExecutionInputs.resolve(issue, %{executable: "codex", default_model: "gpt-5.4-mini"})
  end
end
