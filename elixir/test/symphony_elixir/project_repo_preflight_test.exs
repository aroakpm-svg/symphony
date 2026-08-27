defmodule SymphonyElixir.ProjectRepoPreflightTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectRepoPreflight

  test "project-management mapping passes read-only repository and quality-contract checks" do
    runner = fn
      "gh", ["auth", "status"] ->
        {"authenticated", 0}

      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"main"}}), 0}

      "git", ["ls-remote", "--exit-code", "https://github.com/aroakpm-svg/aroak-project-management.git", "refs/heads/main"] ->
        {"0123456789abcdef\trefs/heads/main\n", 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/contents/package.json", "-H", "Accept: application/vnd.github.raw+json"] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit","build":"next build","db:test":"bash scripts/db-test.sh"}}), 0}
    end

    assert {:ok, receipt} = ProjectRepoPreflight.check("project-management", runner)
    assert receipt.repository == "aroakpm-svg/aroak-project-management"
    assert receipt.default_branch == "main"
    assert receipt.head_sha == "0123456789abcdef"
    assert receipt.required_scripts == ["typecheck", "build", "db:test"]
  end

  test "unknown projects fail closed without running commands" do
    runner = fn _, _ -> flunk("unknown mapping must not execute external commands") end

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check("central-brain", runner)
  end

  test "a repository whose default branch drifts from the mapping fails closed" do
    runner = fn
      "gh", ["auth", "status"] ->
        {"authenticated", 0}

      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"develop"}}), 0}
    end

    assert {:blocked, %{code: :default_branch_mismatch, next_step: next_step}} =
             ProjectRepoPreflight.check("project-management", runner)

    assert next_step == "Restore the repository default branch to main or update the approved mapping."
  end

  test "missing required quality scripts fails closed with the exact missing scripts" do
    runner = fn
      "gh", ["auth", "status"] ->
        {"authenticated", 0}

      "gh", ["repo", "view", "aroakpm-svg/aroak-project-management", "--json", "nameWithOwner,defaultBranchRef"] ->
        {~s({"nameWithOwner":"aroakpm-svg/aroak-project-management","defaultBranchRef":{"name":"main"}}), 0}

      "git", ["ls-remote", "--exit-code", "https://github.com/aroakpm-svg/aroak-project-management.git", "refs/heads/main"] ->
        {"0123456789abcdef\trefs/heads/main\n", 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/contents/package.json", "-H", "Accept: application/vnd.github.raw+json"] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit"}}), 0}
    end

    assert {:blocked, %{code: :required_check_contract_missing, detail: ["build", "db:test"]}} =
             ProjectRepoPreflight.check("project-management", runner)
  end
end
