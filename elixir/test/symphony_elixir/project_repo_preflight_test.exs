defmodule SymphonyElixir.ProjectRepoPreflightTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectRepoPreflight

  test "project-management mapping passes read-only repository and quality-contract checks" do
    runner = fn
      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"main"}}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/git/ref/heads/main"] ->
        {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/contents/package.json?ref=0123456789abcdef0123456789abcdef01234567", "-H", "Accept: application/vnd.github.raw+json"] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit","build":"next build","db:test":"bash scripts/db-test.sh"}}), 0}
    end

    assert {:ok, receipt} = ProjectRepoPreflight.check("project-management", runner)
    assert receipt.repository == "aroakpm-svg/aroak-project-management"
    assert receipt.default_branch == "main"
    assert receipt.head_sha == "0123456789abcdef0123456789abcdef01234567"
    assert receipt.required_scripts == ["typecheck", "build", "db:test"]
  end

  test "unknown projects fail closed without running commands" do
    runner = fn _, _ -> flunk("unknown mapping must not execute external commands") end

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check("central-brain", runner)
  end

  test "a repository whose default branch drifts from the mapping fails closed" do
    runner = fn
      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"develop"}}), 0}
    end

    assert {:blocked, %{code: :default_branch_mismatch, next_step: next_step}} =
             ProjectRepoPreflight.check("project-management", runner)

    assert next_step == "Restore the repository default branch to main or update the approved mapping."
  end

  test "missing required quality scripts fails closed with the exact missing scripts" do
    runner = fn
      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"main"}}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/git/ref/heads/main"] ->
        {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/contents/package.json?ref=0123456789abcdef0123456789abcdef01234567", "-H", "Accept: application/vnd.github.raw+json"] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit"}}), 0}
    end

    assert {:blocked, %{code: :required_check_contract_missing, detail: ["build", "db:test"]}} =
             ProjectRepoPreflight.check("project-management", runner)
  end

  test "malformed metadata, heads, and script values fail closed" do
    assert {:blocked, %{code: :repository_metadata_invalid}} =
             ProjectRepoPreflight.check(
               "project-management",
               sequence_runner([{~s({"nameWithOwner":true}), 0}])
             )

    valid_metadata = ~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"main"}})

    assert {:blocked, %{code: :default_branch_unresolvable}} =
             ProjectRepoPreflight.check(
               "project-management",
               sequence_runner([{valid_metadata, 0}, {~s({"ref":"refs/heads/main","object":{"sha":"short"}}), 0}])
             )

    assert {:blocked, %{code: :required_check_contract_missing, detail: ["typecheck"]}} =
             ProjectRepoPreflight.check(
               "project-management",
               sequence_runner([
                 {valid_metadata, 0},
                 {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0},
                 {~s({"scripts":{"typecheck":" ","build":"next build","db:test":"bash scripts/db-test.sh"}}), 0}
               ])
             )
  end

  test "runner exceptions become a secret-safe blocker" do
    runner = fn _, _ -> raise "token=must-not-escape" end

    assert {:blocked, %{code: :repository_unavailable, detail: "aroakpm-svg/aroak-project-management"}} =
             ProjectRepoPreflight.check("project-management", runner)
  end

  defp sequence_runner(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    fn _, _ -> Agent.get_and_update(agent, fn [result | rest] -> {result, rest} end) end
  end
end
