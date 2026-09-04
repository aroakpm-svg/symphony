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

    assert_receive {:github_request, :post, "https://api.github.com/graphql", headers, false}
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

  test "missing or hidden repositories and refs are permanent authority blockers" do
    for suffix <- ["/aroak-central-brain", "/git/ref/heads/main"] do
      successful = authority_request_fun(self())

      request = fn request ->
        if String.ends_with?(request[:url], suffix),
          do: {:ok, %{status: 404, body: %{"message" => @token}}},
          else: successful.(request)
      end

      assert {:error, :github_repository_not_allowed} = Client.verify(approved_profile(), credential(approved_profile()), expected_actor: @actor, request_fun: request)
    end
  end

  test "GraphQL partial errors and malformed viewer identities never authorize an installation token" do
    for body <- [
          %{"errors" => [%{"message" => @token}], "data" => %{"viewer" => %{"login" => @actor}}},
          %{"errors" => [], "data" => %{"viewer" => %{"login" => @actor}}},
          %{"data" => nil},
          %{"data" => %{"viewer" => nil}},
          %{"data" => %{"viewer" => %{"login" => nil}}},
          %{"data" => %{"viewer" => %{"login" => " "}}}
        ] do
      assert {:error, :github_response_invalid} =
               Client.verify(approved_profile(), credential(approved_profile()),
                 expected_actor: @actor,
                 request_fun: fn request ->
                   assert request[:method] == :post
                   assert request[:url] == "https://api.github.com/graphql"
                   assert request[:json] == %{query: "query { viewer { login } }"}
                   assert request[:redirect] == false
                   {:ok, %{status: 200, body: body}}
                 end
               )
    end
  end

  test "normalizes a forbidden GitHub response" do
    assert {:error, :github_forbidden} =
             Client.verify(approved_profile(), credential(approved_profile()),
               expected_actor: @actor,
               request_fun: fn _request -> {:ok, %{status: 403, body: %{}}} end
             )
  end

  test "primary and secondary HTTP 403 rate limits remain retryable at every authority endpoint" do
    for response <- [
          %{status: 403, headers: %{"x-ratelimit-remaining" => ["0"]}, body: %{}},
          %{status: 403, headers: [{"X-RateLimit-Remaining", "0"}], body: %{}},
          %{status: 403, headers: %{"retry-after" => ["60"]}, body: %{}},
          %{status: 403, body: %{"message" => "You have exceeded a secondary rate limit. " <> @token}}
        ],
        suffix <- ["/graphql", "/installation/repositories?per_page=2", "/aroak-central-brain", "/git/ref/heads/main"] do
      successful = authority_request_fun(self())

      assert {:error, :github_unavailable} =
               Client.verify(approved_profile(), credential(approved_profile()),
                 expected_actor: @actor,
                 request_fun: fn request ->
                   if String.ends_with?(request[:url], suffix), do: {:ok, response}, else: successful.(request)
                 end
               )
    end
  end

  test "authorization failures without rate-limit evidence remain permanent" do
    for response <- [
          %{status: 403, headers: %{"x-ratelimit-remaining" => ["100"]}, body: %{"message" => "Resource not accessible by integration"}},
          %{status: 403, headers: %{"retry-after" => ["invalid"]}, body: %{}},
          %{status: 403, headers: [nil, {42, "0"}, {"retry-after", [nil]}], body: %{}},
          %{status: 403, headers: nil, body: nil}
        ] do
      assert {:error, :github_forbidden} =
               Client.verify(approved_profile(), credential(approved_profile()),
                 expected_actor: @actor,
                 request_fun: fn _ -> {:ok, response} end
               )
    end
  end

  test "package preflight shares retryable rate-limit classification and permanent access failures" do
    for {response, code} <- [
          {%{status: 403, headers: %{"x-ratelimit-remaining" => ["0"]}, body: %{}}, :github_unavailable},
          {%{status: 403, headers: %{"retry-after" => ["60"]}, body: "limited"}, :github_unavailable},
          {%{status: 403, body: %{"message" => "You have exceeded a secondary rate limit."}}, :github_unavailable},
          {%{status: 403, body: %{"message" => "Resource not accessible by integration"}}, :github_forbidden},
          {%{status: 401, body: %{}}, :github_unauthorized},
          {%{status: 404, body: %{}}, :required_check_contract_unreadable}
        ] do
      successful = authority_request_fun(self())

      assert {:blocked, %{code: ^code, detail: nil}} =
               SymphonyElixir.ProjectRepoPreflight.check(approved_profile(),
                 expected_actor: @actor,
                 credential_source: fn ref -> {:ok, %{credential_ref: ref, token: @token, expires_at: nil}} end,
                 request_fun: fn request ->
                   if String.contains?(request[:url], "/contents/package.json"),
                     do: {:ok, response},
                     else: successful.(request)
                 end
               )
    end
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

  test "invalid credential actor and transport callbacks are rejected without sending a request" do
    for credential <- [
          nil,
          %Credential{credential_ref: "wrong", token: @token},
          %Credential{credential_ref: "github-central-brain", token: ""},
          %Credential{credential_ref: "github-central-brain", token: " \n"},
          %Credential{credential_ref: "github-central-brain", token: <<0>>}
        ] do
      assert {:error, :github_authority_invalid} = Client.verify(approved_profile(), credential, expected_actor: @actor, request_fun: fn _ -> flunk("invalid credential requested authority") end)
    end

    for opts <- [[], [expected_actor: " "], [expected_actor: @actor, request_fun: nil]] do
      assert {:error, :github_authority_invalid} = Client.verify(approved_profile(), credential(approved_profile()), opts)
    end

    assert {:error, :github_authority_invalid} = Client.verify(nil, nil, nil)
  end

  test "transport exceptions throws and malformed envelopes return bounded failures" do
    for {request, reason} <- [
          {fn _ -> raise @token end, :github_unavailable},
          {fn _ -> throw(@token) end, :github_unavailable},
          {fn _ -> {:error, @token} end, :github_unavailable},
          {fn _ -> {:unexpected, @token} end, :github_response_invalid}
        ] do
      assert {:error, ^reason} = Client.verify(approved_profile(), credential(approved_profile()), expected_actor: @actor, request_fun: request)
    end
  end

  test "repository identity permissions and head response must remain bound to the approved profile" do
    repository = %{"full_name" => @repository, "default_branch" => @branch, "permissions" => %{"pull" => true, "push" => true}}

    for {suffix, body, reason} <- [
          {"/aroak-central-brain", %{}, :github_response_invalid},
          {"/aroak-central-brain", %{repository | "full_name" => "other/repository"}, :github_repository_not_allowed},
          {"/aroak-central-brain", %{repository | "default_branch" => "other"}, :github_repository_not_allowed},
          {"/aroak-central-brain", %{repository | "permissions" => %{"pull" => "true", "push" => true}}, :github_repository_not_allowed},
          {"/aroak-central-brain", %{repository | "permissions" => %{"pull" => false, "push" => true}}, :github_pull_authority_missing},
          {"/git/ref/heads/main", %{}, :github_response_invalid},
          {"/git/ref/heads/main", %{"ref" => "refs/heads/other", "object" => %{"sha" => @head_sha}}, :github_response_invalid},
          {"/git/ref/heads/main", %{"ref" => "refs/heads/main", "object" => %{"sha" => nil}}, :github_response_invalid}
        ] do
      successful = authority_request_fun(self())

      assert {:error, ^reason} =
               Client.verify(approved_profile(), credential(approved_profile()),
                 expected_actor: @actor,
                 request_fun: fn request ->
                   if String.ends_with?(request[:url], suffix) do
                     {:ok, %{status: 200, body: body}}
                   else
                     successful.(request)
                   end
                 end
               )
    end
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
        "https://api.github.com/installation/repositories?per_page=2" ->
          {:ok, %{status: 200, body: %{"total_count" => 1, "repositories" => [%{"full_name" => @repository}]}}}

        "https://api.github.com/graphql" ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => actor}}}}}

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
