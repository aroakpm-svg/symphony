defmodule SymphonyElixir.GitHubAuthorityClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Logger

  alias SymphonyElixir.GitHubAuthorityClient, as: Client
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @actor "aroak-symphony[bot]"
  @repository "aroakpm-svg/aroak-central-brain"
  @branch "main"
  @head_sha "a1b2c3d4e5f678901234567890abcdef12345678"
  @token "github-authority-token-sentinel"

  test "returns only verified actor and repository authority evidence" do
    profile = approved_profile()
    credential = credential(profile)

    assert {:ok,
            %{
              actor: @actor,
              repository: @repository,
              pull?: true,
              push?: true,
              default_branch: @branch,
              head_sha: @head_sha
            } = receipt} =
             Client.verify(profile, credential,
               expected_actor: @actor,
               request_fun: authority_request_fun(self())
             )

    assert Map.keys(receipt) |> Enum.sort() ==
             [:actor, :default_branch, :head_sha, :pull?, :push?, :repository]

    assert_receive {:github_request, :get, "https://api.github.com/user", headers, false}
    assert {"authorization", "Bearer " <> @token} in headers
    assert_receive {:github_request, :get, "https://api.github.com/repos/aroakpm-svg/aroak-central-brain", ^headers, false}

    assert_receive {:github_request, :get, "https://api.github.com/repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main", ^headers, false}
  end

  test "normalizes an unauthorized GitHub response" do
    assert {:error, :github_unauthorized} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: fn _request -> {:ok, %{status: 401, body: %{}}} end
             )
  end

  test "normalizes a forbidden GitHub response" do
    assert {:error, :github_forbidden} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: fn _request -> {:ok, %{status: 403, body: %{}}} end
             )
  end

  test "rejects a credential whose GitHub actor differs from the trusted actor" do
    assert {:error, :github_unexpected_actor} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: authority_request_fun(self(), actor: "human")
             )
  end

  test "rejects a profile outside the approved repository manifest before making a request" do
    unapproved = %{approved_profile() | repository: "aroakpm-svg/unapproved"}

    assert {:error, :github_repository_not_allowed} =
             Client.verify(unapproved, credential(approved_profile()),
               expected_actor: @actor,
               request_fun: fn _request -> flunk("unapproved repositories must not be requested") end
             )
  end

  test "requires push authority for the approved repository" do
    assert {:error, :github_push_authority_missing} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: authority_request_fun(self(), push?: false)
             )
  end

  test "keeps redirects fail closed without following them" do
    request_fun = fn request ->
      send(self(), {:github_redirect, Keyword.get(request, :redirect)})
      {:ok, %{status: 302, body: %{}}}
    end

    assert {:error, :github_unavailable} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: request_fun
             )

    assert_receive {:github_redirect, false}
  end

  test "accepts only full hexadecimal branch head SHAs" do
    assert {:ok, %{head_sha: sixty_four_sha}} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: authority_request_fun(self(), head_sha: String.duplicate("a", 64))
             )

    assert sixty_four_sha == String.duplicate("a", 64)

    for invalid_sha <- ["a1b2c3d4e5f6", String.duplicate("a", 39), String.duplicate("g", 40)] do
      assert {:error, :github_response_invalid} =
               Client.verify(approved_profile(), credential(approved_profile()),
                 expected_actor: @actor,
                 request_fun: authority_request_fun(self(), head_sha: invalid_sha)
               )
    end
  end

  test "does not expose the credential header or raw failure body outside the request boundary" do
    secret = "github-raw-body-sentinel"
    profile = approved_profile()

    log =
      capture_log(fn ->
        result =
          Client.verify(profile, credential(profile),
            expected_actor: @actor,
            request_fun: fn request ->
              send(self(), {:github_headers, Keyword.fetch!(request, :headers)})
              {:ok, %{status: 500, body: %{"message" => secret}}}
            end
          )

        Logger.error("GitHub authority outcome: #{inspect(result)}")
        send(self(), {:github_result, result})
      end)

    assert_receive {:github_headers, headers}
    assert {"authorization", "Bearer " <> @token} in headers
    assert_receive {:github_result, result}
    assert {:error, :github_unavailable} = result
    refute inspect(result) =~ @token
    refute inspect(result) =~ secret
    refute log =~ @token
    refute log =~ secret
  end

  defp approved_profile do
    %{
      key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: @repository,
      canonical_branch: @branch,
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production"
    }
  end

  defp credential(profile) do
    %Credential{credential_ref: profile.credential_ref, token: @token, expires_at: nil}
  end

  defp authority_request_fun(parent, overrides \\ []) do
    actor = Keyword.get(overrides, :actor, @actor)
    pull? = Keyword.get(overrides, :pull?, true)
    push? = Keyword.get(overrides, :push?, true)
    head_sha = Keyword.get(overrides, :head_sha, @head_sha)

    fn request ->
      method = Keyword.fetch!(request, :method)
      url = Keyword.fetch!(request, :url)
      headers = Keyword.fetch!(request, :headers)
      redirect = Keyword.get(request, :redirect)
      send(parent, {:github_request, method, url, headers, redirect})

      case url do
        "https://api.github.com/user" ->
          {:ok, %{status: 200, body: %{"login" => actor}}}

        "https://api.github.com/repos/aroakpm-svg/aroak-central-brain" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "full_name" => @repository,
               "default_branch" => @branch,
               "permissions" => %{"pull" => pull?, "push" => push?}
             }
           }}

        "https://api.github.com/repos/aroakpm-svg/aroak-central-brain/git/ref/heads/main" ->
          {:ok,
           %{
             status: 200,
             body: %{"ref" => "refs/heads/main", "object" => %{"sha" => head_sha}}
           }}

        _other ->
          flunk("unexpected GitHub request")
      end
    end
  end
end
