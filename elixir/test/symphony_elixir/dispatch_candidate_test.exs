defmodule SymphonyElixir.DispatchCandidateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DispatchCandidate
  alias SymphonyElixir.Linear.Issue

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
  @profiles %{
    version: 1,
    profiles: %{
      "central-brain" => @central_profile,
      "project-management" => @project_management_profile
    }
  }

  test "authorizes refreshed evidence only after binding its approved profile and repository" do
    issue = valid_issue()

    assert {:ok, authorized} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: successful_route_reader())

    assert authorized.project_profile.key == "central-brain"
    assert authorized.repository == "aroakpm-svg/aroak-central-brain"
    assert authorized.routing_revision == 7
  end

  test "skips an issue whose refreshed state is inactive before reading routing" do
    issue = %{valid_issue() | state: "Done"}

    assert {:skip, :inactive_state} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: unexpected_route_reader())
  end

  test "skips an issue whose refreshed labels omit symphony-worker before reading routing" do
    issue = %{valid_issue() | labels: ["other-label"]}

    assert {:skip, :missing_worker_label} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: unexpected_route_reader())
  end

  test "skips an issue whose refreshed project UUID is unknown before reading routing" do
    issue = %{valid_issue() | project_id: "11111111-1111-4111-8111-111111111111"}

    assert {:skip, :unknown_project} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: unexpected_route_reader())
  end

  test "skips an issue moved to a different approved project before reading routing" do
    issue = %{valid_issue() | project_id: @project_management_profile.linear_project_id}

    assert {:skip, :project_changed} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: unexpected_route_reader())
  end

  test "skips when polled profile evidence is not the exact approved profile" do
    changed_profile = %{@central_profile | repository: "aroakpm-svg/unapproved"}
    issue = %{valid_issue() | project_profile: changed_profile}

    assert {:skip, :project_changed} =
             DispatchCandidate.authorize(issue, @profiles, route_reader: unexpected_route_reader())
  end

  test "skips missing exclusive routing" do
    route_reader = fn %Issue{id: "issue-1"} -> {:ineligible, :missing_routing} end

    assert {:skip, :missing_routing} = DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: route_reader)
  end

  test "skips non-exclusive routing" do
    route_reader = fn %Issue{id: "issue-1"} -> {:ineligible, :non_exclusive_routing} end

    assert {:skip, :non_exclusive_routing} =
             DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: route_reader)
  end

  test "skips exclusive routing owned by a different node" do
    route_reader = fn %Issue{id: "issue-1"} -> {:ineligible, :wrong_node} end

    assert {:skip, :wrong_node} = DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: route_reader)
  end

  test "retries transient routing failures using one stable secret-safe reason" do
    route_reader = fn %Issue{id: "issue-1"} -> {:error, :claim_service_unavailable} end

    assert {:retry, :routing_unavailable} =
             DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: route_reader)
  end

  test "retries malformed routing evidence instead of authorizing it" do
    route_reader = fn %Issue{id: "issue-1"} -> {:ok, %{routing_revision: 0}} end

    assert {:retry, :routing_unavailable} =
             DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: route_reader)
  end

  test "fails closed for malformed evidence and options" do
    no_route_opts = [route_reader: unexpected_route_reader()]

    assert {:skip, :inactive_state} =
             DispatchCandidate.authorize(%{valid_issue() | state: nil}, @profiles)

    assert {:skip, :missing_worker_label} =
             DispatchCandidate.authorize(%{valid_issue() | labels: nil}, @profiles, no_route_opts)

    assert {:skip, :missing_worker_label} =
             DispatchCandidate.authorize(%{valid_issue() | labels: [nil]}, @profiles, no_route_opts)

    assert {:skip, :unknown_project} =
             DispatchCandidate.authorize(valid_issue(), nil, no_route_opts)

    assert {:retry, :routing_unavailable} =
             DispatchCandidate.authorize(valid_issue(), @profiles, route_reader: :not_a_function)
  end

  defp valid_issue do
    %Issue{
      id: "issue-1",
      identifier: "ARO-287",
      state: "In Progress",
      labels: ["symphony-worker"],
      project_id: @central_profile.linear_project_id,
      project_profile: @central_profile,
      repository: nil
    }
  end

  defp successful_route_reader do
    fn %Issue{id: "issue-1"} -> {:ok, %{routing_revision: 7}} end
  end

  defp unexpected_route_reader do
    fn _issue -> flunk("routing must not be read after an earlier authorization gate fails") end
  end
end
