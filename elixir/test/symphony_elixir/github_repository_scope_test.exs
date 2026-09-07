defmodule SymphonyElixir.GitHubRepositoryScopeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubAuthorityClient
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @repository "aroakpm-svg/aroak-central-brain"
  @other "aroakpm-svg/aroak-project-management"
  @secret "synthetic-scope-token"
  @profile %{
    key: "central-brain",
    linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
    repository: @repository,
    canonical_branch: "main",
    workspace_namespace: "central-brain",
    credential_ref: "github-central-brain",
    environment: "local_non_production"
  }

  test "target write permission does not authorize a multi-repository child token" do
    body = %{"total_count" => 2, "repositories" => [%{"full_name" => @repository}, %{"full_name" => @other}]}
    assert {:error, :github_repository_not_allowed} = verify(body)
    refute_received :target_requested
  end

  test "only the selected singleton repository is valid scope evidence" do
    assert {:ok, receipt} = verify(%{"total_count" => 1, "repositories" => [%{"full_name" => @repository}]})
    refute :erlang.term_to_binary(receipt) =~ @secret

    for body <- [
          %{"total_count" => 0, "repositories" => []},
          %{"total_count" => 1, "repositories" => [%{"full_name" => @other}]},
          %{"total_count" => 100, "repositories" => [%{"full_name" => @repository}]},
          %{"total_count" => 1, "repositories" => []},
          %{"repositories" => [%{"full_name" => @repository}]}
        ] do
      assert {:error, reason} = verify(body)
      assert reason in [:github_repository_not_allowed, :github_response_invalid]
    end
  end

  test "unavailable scope evidence cannot authorize child credentials" do
    for {status, reason} <- [{401, :github_unauthorized}, {403, :github_forbidden}, {500, :github_unavailable}] do
      assert {:error, ^reason} = verify(%{"secret" => @secret}, status)
      refute_received :target_requested
    end
  end

  defp verify(scope_body, status \\ 200) do
    GitHubAuthorityClient.verify(@profile, %Credential{credential_ref: @profile.credential_ref, token: @secret},
      expected_actor: "app[bot]",
      request_fun: fn request ->
        assert request[:redirect] == false

        body =
          case request[:url] do
            "https://api.github.com/graphql" ->
              %{"data" => %{"viewer" => %{"login" => "app[bot]"}}}

            "https://api.github.com/installation/repositories?per_page=2" ->
              scope_body

            "https://api.github.com/repos/" <> @repository ->
              send(self(), :target_requested)
              %{"full_name" => @repository, "default_branch" => "main", "permissions" => %{"pull" => true, "push" => true}}

            "https://api.github.com/repos/" <> @repository <> "/git/ref/heads/main" ->
              %{"ref" => "refs/heads/main", "object" => %{"sha" => String.duplicate("a", 40)}}
          end

        response_status = if String.contains?(request[:url], "/installation/"), do: status, else: 200
        {:ok, %{status: response_status, body: body}}
      end
    )
  end
end
