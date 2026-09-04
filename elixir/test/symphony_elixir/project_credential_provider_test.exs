defmodule SymphonyElixir.ProjectCredentialProviderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubCredentialResolver.Credential
  alias SymphonyElixir.{ProjectCredentialProvider, ProjectExecutionContext}

  @central_ref "github-central-brain"

  test "resolves only the context reference through the canonical source" do
    token = opaque_value("fresh")
    test_pid = self()

    source = fn ref ->
      send(test_pid, {:resolved, ref})
      {:ok, %{credential_ref: ref, token: token, expires_at: nil}}
    end

    assert {:ok, %Credential{credential_ref: @central_ref, token: ^token} = credential} =
             ProjectCredentialProvider.resolve(context(), credential_source: source)

    assert_received {:resolved, @central_ref}
    assert {:ok, %{"GH_TOKEN" => ^token}} = ProjectCredentialProvider.environment(credential)
  end

  test "the default source fails closed" do
    assert {:error, :credential_source_unconfigured} = ProjectCredentialProvider.resolve(context(), [])
  end

  test "canonical resolver failures stay typed and secret safe" do
    secret = opaque_value("must-not-escape")

    outcomes = [
      {{:error, {:missing, secret}}, :credential_source_missing},
      {{:error, {:ambiguous, secret}}, :credential_source_conflict},
      {{:ok, %{credential_ref: "github-project-management", token: secret, expires_at: nil}}, :credential_reference_mismatch}
    ]

    for {source_result, expected_reason} <- outcomes do
      source = fn @central_ref -> source_result end
      assert {:error, ^expected_reason} = ProjectCredentialProvider.resolve(context(), credential_source: source)
      refute inspect(expected_reason) =~ secret
    end
  end

  test "only a validated canonical credential can become the minimal child environment" do
    token = opaque_value("child")

    assert {:ok, %{"GH_TOKEN" => ^token}} =
             ProjectCredentialProvider.environment(%Credential{
               credential_ref: @central_ref,
               token: token,
               expires_at: nil
             })

    assert {:error, :credential_resolver_failed} = ProjectCredentialProvider.environment(%{})
  end

  defp context do
    %ProjectExecutionContext{
      issue_id: "issue-central-brain",
      issue_identifier: "ARO-196",
      profile_key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: @central_ref,
      environment: "local_non_production",
      routing_revision: 1
    }
  end

  defp opaque_value(label), do: "#{label}-#{System.unique_integer([:positive, :monotonic])}"
end
