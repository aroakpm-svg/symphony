defmodule SymphonyElixir.ProjectExecutionContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProjectExecutionContext

  @central_brain %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: "aroakpm-svg/aroak-central-brain",
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }

  @project_management %{
    key: "project-management",
    linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
    repository: "aroakpm-svg/aroak-project-management",
    canonical_branch: "main",
    workspace_namespace: "project-management",
    credential_ref: "github-project-management",
    environment: "local_non_production"
  }

  test "constructs immutable contexts for each approved project profile" do
    assert {:ok, %{profile_key: "central-brain", workspace_namespace: "central-brain"}} =
             authorized_issue()
             |> ProjectExecutionContext.from_issue()

    assert {:ok, %{profile_key: "project-management", workspace_namespace: "project-management"}} =
             authorized_issue(
               project_id: "708053E0-F42C-4E93-BEC4-7ABBB37E74AF",
               project_profile: @project_management,
               repository: "aroakpm-svg/aroak-project-management"
             )
             |> ProjectExecutionContext.from_issue()
  end

  test "fails closed when the project profile is missing" do
    assert {:error, :missing_project_profile} =
             authorized_issue(project_profile: nil)
             |> ProjectExecutionContext.from_issue()
  end

  test "rejects malformed issue and profile identities" do
    assert {:error, :invalid_project_profile} = ProjectExecutionContext.from_issue(%{})

    for {attrs, reason} <- [
          {[id: nil], :invalid_issue_id},
          {[identifier: ""], :invalid_issue_identifier},
          {[project_id: "not-a-uuid"], :invalid_project_id},
          {[project_profile: "central-brain"], :invalid_project_profile},
          {[project_profile: Map.put(@central_brain, :linear_project_id, "not-a-uuid")], :invalid_project_id}
        ] do
      assert {:error, ^reason} =
               attrs
               |> authorized_issue()
               |> ProjectExecutionContext.from_issue()
    end
  end

  test "rejects an issue assigned to a different Linear project" do
    assert {:error, :project_id_mismatch} =
             authorized_issue(project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af")
             |> ProjectExecutionContext.from_issue()
  end

  test "rejects an issue repository that differs from its profile" do
    assert {:error, :repository_mismatch} =
             authorized_issue(repository: "aroakpm-svg/aroak-project-management")
             |> ProjectExecutionContext.from_issue()
  end

  test "rejects missing routing evidence" do
    assert {:error, :missing_routing_revision} =
             authorized_issue(routing_revision: nil)
             |> ProjectExecutionContext.from_issue()
  end

  test "rejects malformed workspace namespaces" do
    malformed_profile = Map.put(@central_brain, :workspace_namespace, "../escape")

    assert {:error, :invalid_workspace_namespace} =
             authorized_issue(project_profile: malformed_profile)
             |> ProjectExecutionContext.from_issue()
  end

  test "rejects every environment except local_non_production" do
    for environment <- ["production", "staging", nil] do
      profile = Map.put(@central_brain, :environment, environment)

      assert {:error, :environment_not_allowed} =
               authorized_issue(project_profile: profile)
               |> ProjectExecutionContext.from_issue()
    end
  end

  test "does not expose a credential reference in errors or safe metadata" do
    credential_ref = "submitted-credential-reference"
    profile = Map.put(@central_brain, :credential_ref, credential_ref)
    issue = authorized_issue(project_profile: profile, repository: "aroakpm-svg/other")

    assert {:error, reason} = ProjectExecutionContext.from_issue(issue)
    assert is_atom(reason)
    refute inspect(reason) =~ credential_ref

    assert {:ok, context} = ProjectExecutionContext.from_issue(authorized_issue())
    metadata = ProjectExecutionContext.safe_metadata(context)

    refute Map.has_key?(metadata, :credential_ref)
    refute inspect(metadata) =~ "github-central-brain"

    assert metadata == %{
             issue_id: "issue-1",
             issue_identifier: "ARO-286",
             profile_key: "central-brain",
             repository: "aroakpm-svg/aroak-central-brain",
             canonical_branch: "main",
             workspace_namespace: "central-brain",
             environment: "local_non_production",
             routing_revision: 7
           }
  end

  defp authorized_issue(attrs \\ []) do
    %Issue{
      id: "issue-1",
      identifier: "ARO-286",
      project_id: @central_brain.linear_project_id,
      project_profile: @central_brain,
      repository: @central_brain.repository,
      routing_revision: 7
    }
    |> Map.merge(Map.new(attrs))
  end
end
