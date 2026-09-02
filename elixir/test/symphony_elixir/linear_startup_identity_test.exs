defmodule SymphonyElixir.LinearStartupIdentityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  test "validates a viewer identity through the read-only viewer request" do
    request_fun = fn payload, _headers ->
      send(self(), {:viewer_request, payload})
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-123"}}}}}
    end

    assert {:ok, %{viewer_id: "viewer-123"}} = Client.validate_identity(request_fun: request_fun)
    assert_receive {:viewer_request, %{"query" => query, "variables" => %{}}}
    assert query =~ "query SymphonyLinearViewer"
    assert query =~ "viewer"
  end

  test "validates access to every configured project identity and rejects a wrong workspace" do
    project_ids = [
      "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      "708053e0-f42c-4e93-bec4-7abbb37e74af"
    ]

    request_fun = fn %{"query" => query, "variables" => variables} = payload, _headers ->
      send(self(), {:identity_request, payload})

      cond do
        query =~ "SymphonyLinearViewer" ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-123"}}}}}

        variables == %{projectId: hd(project_ids)} ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"project" => %{"id" => hd(project_ids)}}}
           }}

        variables == %{projectId: List.last(project_ids)} ->
          {:ok, %{status: 200, body: %{"data" => %{"project" => nil}}}}
      end
    end

    assert {:error, :linear_workspace_mismatch} =
             Client.validate_identity(project_ids: project_ids, request_fun: request_fun)

    assert_receive {:identity_request, %{"query" => viewer_query, "variables" => %{}}}
    assert viewer_query =~ "SymphonyLinearViewer"

    assert_receive {:identity_request,
                    %{
                      "query" => project_query,
                      "variables" => %{projectId: first_project_id}
                    }}

    assert project_query =~ "SymphonyLinearProjectIdentity"
    assert first_project_id == hd(project_ids)

    assert_receive {:identity_request, %{"variables" => %{projectId: second_project_id}}}

    assert second_project_id == List.last(project_ids)
  end

  test "classifies authentication, identity, response, and transport failures without exposing payloads" do
    cases = [
      {{:ok, %{status: 401, body: "secret unauthorized body"}}, :linear_unauthorized},
      {{:ok, %{status: 403, body: "secret forbidden body"}}, :linear_forbidden},
      {{:ok, %{status: 200, body: %{"errors" => [%{"extensions" => %{"code" => "UNAUTHENTICATED"}}]}}}, :linear_unauthorized},
      {{:ok,
        %{
          status: 200,
          body: %{
            "data" => %{"viewer" => %{"id" => "viewer-123"}},
            "errors" => [%{"extensions" => %{"code" => "FORBIDDEN"}}]
          }
        }}, :linear_forbidden},
      {{:ok, %{status: 200, body: %{"data" => %{"viewer" => nil}}}}, :linear_identity_missing},
      {{:ok, %{status: 200, body: "{"}}, :linear_response_invalid},
      {{:error, :timeout}, :linear_unavailable},
      {{:error, :econnrefused}, :linear_unavailable}
    ]

    for {request_result, expected} <- cases do
      request_fun = fn _payload, _headers -> request_result end

      assert {:error, ^expected} = Client.validate_identity(request_fun: request_fun)
    end
  end
end
