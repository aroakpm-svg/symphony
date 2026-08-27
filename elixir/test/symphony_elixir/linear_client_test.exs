defmodule SymphonyElixir.Linear.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  test "normalizes Linear project evidence without assigning local authorization" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "ARO-289",
      "project" => %{"id" => "project-uuid", "slugId" => "central-brain"}
    }

    issue = Client.normalize_issue_for_test(raw_issue)

    assert issue.project_id == "project-uuid"
    assert issue.project_slug == "central-brain"
    assert is_nil(issue.project_profile)
    assert is_nil(issue.repository)
  end

  test "requests project identity when refreshing issues by ID" do
    graphql_fun = fn query, _variables ->
      send(self(), {:linear_query, query})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issue_states_by_ids_for_test(["issue-1"], graphql_fun)
    assert_receive {:linear_query, query}
    assert query =~ ~r/project\s*\{\s*id\s*slugId\s*\}/
  end

  test "uses an approved profile's Linear project UUID for candidate polling" do
    profile = %{key: "central-brain", linear_project_id: "central-linear-id"}

    graphql_fun = fn query, variables ->
      send(self(), {:linear_query, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
         }
       }}
    end

    assert {:ok, []} = Client.fetch_candidate_issues_for_test(profile, ["Todo"], graphql_fun)

    assert_receive {:linear_query, query, %{projectId: "central-linear-id", stateNames: ["Todo"]}}
    assert query =~ "project: {id: {eq: $projectId}}"
  end
end
