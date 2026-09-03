defmodule SymphonyElixir.GitHubCredentialResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.GitHubCredentialResolver, as: Resolver
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @central_ref "github-central-brain"
  @management_ref "github-project-management"

  setup do
    previous = Application.get_env(:symphony_elixir, :github_credential_source)
    Application.delete_env(:symphony_elixir, :github_credential_source)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :github_credential_source)
      else
        Application.put_env(:symphony_elixir, :github_credential_source, previous)
      end
    end)

    :ok
  end

  test "resolves an approved reference through the trusted source" do
    source = fn @central_ref -> {:ok, %{credential_ref: @central_ref, token: "opaque-token", expires_at: nil}} end

    assert {:ok, %Credential{credential_ref: @central_ref, token: "opaque-token", expires_at: nil}} =
             Resolver.resolve(@central_ref, credential_source: source)
  end

  test "uses the application source when an option source is absent" do
    source = fn @management_ref -> {:ok, %{credential_ref: @management_ref, token: "opaque-token", expires_at: nil}} end
    Application.put_env(:symphony_elixir, :github_credential_source, source)

    assert {:ok, %Credential{credential_ref: @management_ref}} = Resolver.resolve(@management_ref, [])
  end

  test "fails closed when no trusted source is configured" do
    assert {:error, :credential_source_unconfigured} = Resolver.resolve(@central_ref, [])
  end

  test "rejects competing source results" do
    secret = "credential-source-conflict-sentinel"
    conflict = fn @central_ref -> {:error, {:conflict, secret}} end

    assert {:error, :credential_source_conflict} =
             Resolver.resolve(@central_ref, credential_source: conflict)

    refute inspect(:credential_source_conflict) =~ secret
  end

  test "normalizes ambiguous source results to a source conflict" do
    secret = "credential-source-ambiguous-sentinel"
    ambiguous = fn @central_ref -> {:error, {:ambiguous, secret}} end

    assert {:error, :credential_source_conflict} =
             Resolver.resolve(@central_ref, credential_source: ambiguous)

    refute inspect(:credential_source_conflict) =~ secret
  end

  test "rejects a source result bound to another reference" do
    wrong_ref = fn @central_ref ->
      {:ok, %{credential_ref: @management_ref, token: "opaque-token", expires_at: nil}}
    end

    assert {:error, :credential_reference_mismatch} =
             Resolver.resolve(@central_ref, credential_source: wrong_ref)
  end

  test "rejects expired credentials" do
    expired = fn @central_ref ->
      {:ok, %{credential_ref: @central_ref, token: "opaque-token", expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}}
    end

    assert {:error, :credential_expired} =
             Resolver.resolve(@central_ref, credential_source: expired)
  end

  test "normalizes malformed and exceptional sources to secret-free failures" do
    secret = "credential-shaped-malformed-sentinel"

    for result <- [
          {:ok, %{credential_ref: @central_ref, token: secret}},
          {:ok, %{credential_ref: @central_ref, token: <<0>>}},
          {:unexpected, secret}
        ] do
      source = fn @central_ref -> result end

      assert {:error, :credential_resolver_failed} =
               Resolver.resolve(@central_ref, credential_source: source)
    end

    missing_source = fn @central_ref -> {:error, {:missing, secret}} end

    assert {:error, :credential_source_missing} =
             Resolver.resolve(@central_ref, credential_source: missing_source)

    raising_source = fn @central_ref -> raise secret <> " raised" end

    log =
      capture_log(fn ->
        assert {:error, :credential_resolver_failed} =
                 Resolver.resolve(@central_ref, credential_source: raising_source)
      end)

    refute log =~ secret
    refute inspect(:credential_resolver_failed) =~ secret
  end

  test "does not expose credential-shaped values in source conflicts or raised text" do
    secret = "credential-shaped-conflict-sentinel"
    source = fn @central_ref -> raise ArgumentError, secret end

    result = Resolver.resolve(@central_ref, credential_source: source)
    assert {:error, reason} = result
    refute inspect(reason) =~ secret
    refute Exception.message(%RuntimeError{message: inspect(reason)}) =~ secret
  end
end
