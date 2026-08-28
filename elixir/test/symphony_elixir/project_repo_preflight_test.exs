defmodule SymphonyElixir.ProjectRepoPreflightTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.ProjectRepoPreflight

  @central_profile %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: "aroakpm-svg/aroak-central-brain",
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }
  @project_management_profile %{
    key: "project-management",
    linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
    repository: "aroakpm-svg/aroak-project-management",
    canonical_branch: "main",
    workspace_namespace: "project-management",
    credential_ref: "github-project-management",
    environment: "local_non_production"
  }

  test "project-management profile passes its repository and quality-contract checks" do
    runner = fn
      "gh", ["api", "repos/aroakpm-svg/aroak-project-management", "--hostname", "github.com"] ->
        {~s({"full_name":"aroakpm-svg/aroak-project-management","default_branch":"main"}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/git/ref/heads/main", "--hostname", "github.com"] ->
        {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0}

      "gh",
      [
        "api",
        "repos/aroakpm-svg/aroak-project-management/contents/package.json?ref=0123456789abcdef0123456789abcdef01234567",
        "--hostname",
        "github.com",
        "-H",
        "Accept: application/vnd.github.raw+json"
      ] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit","build":"next build","db:test":"bash scripts/db-test.sh"}}), 0}
    end

    assert {:ok, receipt} = ProjectRepoPreflight.check(@project_management_profile, runner)
    assert receipt.repository == "aroakpm-svg/aroak-project-management"
    assert receipt.default_branch == "main"
    assert receipt.head_sha == "0123456789abcdef0123456789abcdef01234567"
    assert receipt.required_scripts == ["typecheck", "build", "db:test"]
  end

  test "central-brain profile supplies its repository and quality-contract checks" do
    runner = fn
      "gh", ["api", "repos/aroakpm-svg/aroak-central-brain", "--hostname", "github.com"] ->
        {~s({"full_name":"aroakpm-svg/aroak-central-brain","default_branch":"main"}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main", "--hostname", "github.com"] ->
        {~s({"ref":"refs/heads/main","object":{"sha":"abcdef0123456789abcdef0123456789abcdef01"}}), 0}

      "gh",
      [
        "api",
        "repos/aroakpm-svg/aroak-central-brain/contents/package.json?ref=abcdef0123456789abcdef0123456789abcdef01",
        "--hostname",
        "github.com",
        "-H",
        "Accept: application/vnd.github.raw+json"
      ] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit","build":"next build","test":"node --test"}}), 0}
    end

    assert {:ok, receipt} = ProjectRepoPreflight.check(@central_profile, runner)
    assert receipt.project == "central-brain"
    assert receipt.repository == "aroakpm-svg/aroak-central-brain"
    assert receipt.default_branch == "main"
    assert receipt.head_sha == "abcdef0123456789abcdef0123456789abcdef01"
    assert receipt.required_scripts == ["typecheck", "build", "test"]
  end

  test "unknown profiles fail closed without running commands" do
    runner = fn _, _ -> flunk("unknown mapping must not execute external commands") end
    unknown = %{@central_profile | key: "unknown"}

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check(unknown, runner)
  end

  test "incomplete profile evidence fails closed without running commands" do
    runner = fn _, _ -> flunk("incomplete profile must not execute external commands") end

    assert {:blocked, %{code: :project_mapping_missing}} =
             ProjectRepoPreflight.check(
               %{key: "central-brain", repository: "aroakpm-svg/aroak-central-brain", canonical_branch: "main"},
               runner
             )
  end

  test "GitHub metadata from another repository fails closed" do
    runner = fn
      "gh", ["api", "repos/aroakpm-svg/aroak-central-brain", "--hostname", "github.com"] ->
        {~s({"full_name":"aroakpm-svg/aroak-project-management","default_branch":"main"}), 0}
    end

    assert {:blocked, %{code: :repository_mismatch, detail: "aroakpm-svg/aroak-project-management"}} =
             ProjectRepoPreflight.check(@central_profile, runner)
  end

  test "a repository whose default branch drifts from the mapping fails closed" do
    runner = fn
      "gh", ["api", "repos/aroakpm-svg/aroak-project-management", "--hostname", "github.com"] ->
        {~s({"full_name":"aroakpm-svg/aroak-project-management","default_branch":"develop"}), 0}
    end

    assert {:blocked, %{code: :default_branch_mismatch, next_step: next_step}} =
             ProjectRepoPreflight.check(@project_management_profile, runner)

    assert next_step == "Restore the repository default branch to main or update the approved mapping."
  end

  test "missing required quality scripts fails closed with the exact missing scripts" do
    runner = fn
      "gh", ["api", "repos/aroakpm-svg/aroak-project-management", "--hostname", "github.com"] ->
        {~s({"full_name":"aroakpm-svg/aroak-project-management","default_branch":"main"}), 0}

      "gh", ["api", "repos/aroakpm-svg/aroak-project-management/git/ref/heads/main", "--hostname", "github.com"] ->
        {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0}

      "gh",
      [
        "api",
        "repos/aroakpm-svg/aroak-project-management/contents/package.json?ref=0123456789abcdef0123456789abcdef01234567",
        "--hostname",
        "github.com",
        "-H",
        "Accept: application/vnd.github.raw+json"
      ] ->
        {~s({"scripts":{"typecheck":"tsc --noEmit"}}), 0}
    end

    assert {:blocked, %{code: :required_check_contract_missing, detail: ["build", "db:test"]}} =
             ProjectRepoPreflight.check(@project_management_profile, runner)
  end

  test "malformed metadata, heads, and script values fail closed" do
    assert {:blocked, %{code: :repository_metadata_invalid}} =
             ProjectRepoPreflight.check(
               @project_management_profile,
               sequence_runner([{~s({"nameWithOwner":true}), 0}])
             )

    valid_metadata = ~s({"full_name":"aroakpm-svg/aroak-project-management","default_branch":"main"})

    assert {:blocked, %{code: :default_branch_unresolvable}} =
             ProjectRepoPreflight.check(
               @project_management_profile,
               sequence_runner([{valid_metadata, 0}, {~s({"ref":"refs/heads/main","object":{"sha":"short"}}), 0}])
             )

    assert {:blocked, %{code: :required_check_contract_missing, detail: ["typecheck"]}} =
             ProjectRepoPreflight.check(
               @project_management_profile,
               sequence_runner([
                 {valid_metadata, 0},
                 {~s({"ref":"refs/heads/main","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}), 0},
                 {~s({"scripts":{"typecheck":" ","build":"next build","db:test":"bash scripts/db-test.sh"}}), 0}
               ])
             )
  end

  test "runner exceptions become a secret-safe blocker" do
    runner = fn _, _ -> raise "token=must-not-escape" end

    log =
      capture_log(fn ->
        assert {:blocked, %{code: :repository_unavailable, detail: "aroakpm-svg/aroak-project-management"}} =
                 ProjectRepoPreflight.check(@project_management_profile, runner)
      end)

    refute log =~ "token=must-not-escape"
  end

  defp sequence_runner(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    fn _, _ -> Agent.get_and_update(agent, fn [result | rest] -> {result, rest} end) end
  end
end
