defmodule SymphonyElixir.ProjectCredentialProviderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectCredentialProvider
  alias SymphonyElixir.ProjectExecutionContext

  @central_ref "github-central-brain"
  @management_ref "github-project-management"

  test "each profile resolves only its selected reference and keeps environments isolated" do
    central_value = opaque_value("central")
    management_value = opaque_value("management")
    test_pid = self()

    resolver = fn credential_ref ->
      send(test_pid, {:resolved, credential_ref})

      case credential_ref do
        @central_ref -> {:ok, {@central_ref, %{"GH_TOKEN" => central_value}}}
        @management_ref -> {:ok, {@management_ref, %{"GITHUB_TOKEN" => management_value}}}
      end
    end

    assert {:ok, central_env} =
             ProjectCredentialProvider.resolve(context("central-brain", @central_ref),
               credential_provider: resolver
             )

    assert_received {:resolved, @central_ref}
    refute_received {:resolved, @management_ref}
    assert central_env == %{"GH_TOKEN" => central_value}
    refute Map.has_key?(central_env, "GITHUB_TOKEN")
    central_runner = fn env -> send(test_pid, {:central_runner, env["GH_TOKEN"], env["GITHUB_TOKEN"]}) end
    central_runner.(central_env)
    assert_received {:central_runner, ^central_value, nil}

    assert {:ok, management_env} =
             ProjectCredentialProvider.resolve(context("project-management", @management_ref),
               credential_provider: resolver
             )

    assert_received {:resolved, @management_ref}
    refute_received {:resolved, @central_ref}
    assert management_env == %{"GITHUB_TOKEN" => management_value}
    refute Map.has_key?(management_env, "GH_TOKEN")
    management_runner = fn env -> send(test_pid, {:management_runner, env["GITHUB_TOKEN"], env["GH_TOKEN"]}) end
    management_runner.(management_env)
    assert_received {:management_runner, ^management_value, nil}
  end

  test "the default provider fails closed" do
    assert {:error, :credential_provider_unconfigured} =
             ProjectCredentialProvider.resolve(context("central-brain", @central_ref), [])
  end

  test "missing, ambiguous, and wrong-reference results fail closed without diagnostics" do
    context = context("central-brain", @central_ref)
    secret = opaque_value("must-not-escape")

    outcomes = [
      {{:error, {:missing, secret}}, :credential_not_found},
      {{:error, {:ambiguous, secret}}, :credential_ambiguous},
      {{:ok, {@management_ref, %{"TOKEN" => secret}}}, :credential_reference_mismatch}
    ]

    for {provider_result, expected_reason} <- outcomes do
      resolver = fn @central_ref -> provider_result end

      assert {:error, ^expected_reason} =
               ProjectCredentialProvider.resolve(context, credential_provider: resolver)

      refute inspect(expected_reason) =~ secret
    end
  end

  test "invalid environment keys and values are rejected without returning material" do
    context = context("central-brain", @central_ref)
    secret = opaque_value("invalid")

    for invalid_env <- [
          %{GH_TOKEN: secret},
          %{"LINEAR_API_KEY" => secret},
          %{"NPM_TOKEN" => secret},
          %{"NODE_OPTIONS" => secret},
          %{"HOME" => secret},
          %{"GH_CONFIG_DIR" => secret},
          %{"" => secret},
          %{"BAD=KEY" => secret},
          %{"BAD\0KEY" => secret},
          %{"GH_TOKEN" => nil}
        ] do
      resolver = fn @central_ref -> {:ok, {@central_ref, invalid_env}} end

      assert {:error, :invalid_credential_environment} =
               ProjectCredentialProvider.resolve(context, credential_provider: resolver)
    end
  end

  test "provider exceptions are collapsed to a non-secret reason" do
    secret = opaque_value("exception")
    resolver = fn @central_ref -> raise secret end

    assert {:error, :credential_provider_failed} =
             ProjectCredentialProvider.resolve(context("central-brain", @central_ref),
               credential_provider: resolver
             )

    refute inspect(:credential_provider_failed) =~ secret
  end

  defp context(profile_key, credential_ref) do
    %ProjectExecutionContext{
      issue_id: "issue-#{profile_key}",
      issue_identifier: "ARO-286-#{profile_key}",
      profile_key: profile_key,
      linear_project_id: "11111111-1111-4111-8111-111111111111",
      repository: "owner/#{profile_key}",
      canonical_branch: "main",
      workspace_namespace: profile_key,
      credential_ref: credential_ref,
      environment: "local_non_production",
      routing_revision: 1
    }
  end

  defp opaque_value(label) do
    "#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
