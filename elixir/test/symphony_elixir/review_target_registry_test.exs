defmodule SymphonyElixir.ReviewTargetRegistryTest do
  use ExUnit.Case

  alias SymphonyElixir.ReviewTargetRegistry

  @head_sha String.duplicate("a", 40)

  test "parses an explicit allowlist of independently identified targets" do
    assert {:ok, targets} =
             ReviewTargetRegistry.parse([
               %{
                 "repository" => "aroakpm-svg/aroak-central-brain",
                 "pull_request_number" => 25,
                 "head_sha" => @head_sha
               },
               %{
                 "repository" => "aroakpm-svg/symphony",
                 "pull_request_number" => 25,
                 "head_sha" => @head_sha
               }
             ])

    assert length(targets) == 2
  end

  test "duplicate target identities are rejected" do
    target = %{
      "repository" => "aroakpm-svg/symphony",
      "pull_request_number" => 25,
      "head_sha" => @head_sha
    }

    assert {:error, {:duplicate_target, _key}} = ReviewTargetRegistry.parse([target, target])
  end

  test "missing or malformed environment registry fails closed" do
    previous = System.get_env("SYMPHONY_REVIEW_TARGETS")

    on_exit(fn ->
      if previous, do: System.put_env("SYMPHONY_REVIEW_TARGETS", previous), else: System.delete_env("SYMPHONY_REVIEW_TARGETS")
    end)

    System.delete_env("SYMPHONY_REVIEW_TARGETS")
    assert {:error, {:missing_environment, "SYMPHONY_REVIEW_TARGETS"}} = ReviewTargetRegistry.from_env()

    System.put_env("SYMPHONY_REVIEW_TARGETS", "not-json")
    assert {:error, {:invalid_json, _reason}} = ReviewTargetRegistry.from_env()
  end
end
