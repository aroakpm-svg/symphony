defmodule SymphonyElixir.GitHubCredentialResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias SymphonyElixir.GitHubCredentialResolver, as: Resolver
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @central_ref "github-central-brain"
  @management_ref "github-project-management"

  defmodule HostSource do
    def resolve(ref), do: {:ok, %{credential_ref: ref, token: "synthetic-host-token", expires_at: nil}}
  end

  defmodule BrokenCalendar do
    def day_rollover_relative_to_midnight_utc, do: {0, 1}
    def naive_datetime_to_iso_days(_, _, _, _, _, _, _), do: throw("synthetic-calendar-secret")
  end

  test "a source supplied calendar cannot throw secret material out of expiry validation" do
    expiry = %{DateTime.utc_now() | calendar: BrokenCalendar}

    assert {:error, :credential_resolver_failed} =
             Resolver.resolve(@central_ref,
               credential_source: fn ref -> {:ok, %{credential_ref: ref, token: "synthetic", expires_at: expiry}} end
             )
  end

  test "invalid caller inputs and unloaded or malformed callbacks fail before source invocation" do
    for {ref, opts} <- [
          {nil, []},
          {@central_ref, nil},
          {"unapproved", []},
          {@central_ref, [credential_scope: :invalid]},
          {@central_ref, [credential_source: :not_a_source]},
          {@central_ref, [credential_source: 42]}
        ] do
      assert {:error, :credential_resolver_failed} = Resolver.resolve(ref, opts)
    end

    assert {:ok, %Credential{token: "synthetic-host-token"}} = Resolver.resolve(@central_ref, credential_source: HostSource)
  end

  test "worker source is scoped independently but local duplicate sources still fail closed" do
    Application.put_env(:symphony_elixir, :github_credential_source, HostSource)
    assert {:error, :credential_source_conflict} = Resolver.resolve(@central_ref, credential_source: HostSource)
    worker_opts = [credential_scope: :worker, credential_source: HostSource]
    assert {:ok, %Credential{}} = Resolver.resolve(@central_ref, worker_opts)
    assert {:error, :credential_source_unconfigured} = Resolver.resolve(@central_ref, credential_scope: :worker)
    assert Application.get_env(:symphony_elixir, :github_credential_source) == HostSource
  end

  test "blank NUL malformed expiry and malformed source envelopes cannot yield credentials" do
    for result <- [
          {:ok, %{credential_ref: @central_ref, token: "", expires_at: nil}},
          {:ok, %{credential_ref: @central_ref, token: " \t\n", expires_at: nil}},
          {:ok, %{credential_ref: @central_ref, token: <<0>>, expires_at: nil}},
          {:ok, %{credential_ref: @central_ref, token: "synthetic", expires_at: :invalid}},
          {:ok, %{a: 1, b: 2, c: 3}},
          {:ok, %{credential_ref: @central_ref, token: "synthetic", expires_at: %{DateTime.utc_now() | year: nil}}}
        ] do
      source = fn _ -> result end
      assert {:error, :credential_resolver_failed} = Resolver.resolve(@central_ref, credential_source: source)
    end
  end

  test "unexpired host credentials pass and source throws or plain failure tags are bounded" do
    future = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, %Credential{expires_at: ^future}} =
             Resolver.resolve(@central_ref,
               credential_source: fn ref -> {:ok, %{credential_ref: ref, token: "synthetic", expires_at: future}} end
             )

    for reason <- [:missing, :conflict, :ambiguous] do
      expected = if reason == :missing, do: :credential_source_missing, else: :credential_source_conflict
      assert {:error, ^expected} = Resolver.resolve(@central_ref, credential_source: fn _ -> {:error, reason} end)
    end

    assert {:error, :credential_resolver_failed} =
             Resolver.resolve(@central_ref,
               credential_source: fn _ -> throw("synthetic-secret") end
             )
  end

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
    assert_secret_safe(
      fn -> Resolver.resolve(@central_ref, []) end,
      "credential-source-unconfigured-sentinel",
      :credential_source_unconfigured
    )
  end

  test "rejects competing source results" do
    secret = "credential-source-conflict-sentinel"
    conflict = fn @central_ref -> {:error, {:conflict, secret}} end

    assert_secret_safe(
      fn -> Resolver.resolve(@central_ref, credential_source: conflict) end,
      secret,
      :credential_source_conflict
    )
  end

  test "normalizes ambiguous source results to a source conflict" do
    secret = "credential-source-ambiguous-sentinel"
    ambiguous = fn @central_ref -> {:error, {:ambiguous, secret}} end

    assert_secret_safe(
      fn -> Resolver.resolve(@central_ref, credential_source: ambiguous) end,
      secret,
      :credential_source_conflict
    )
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

      assert_secret_safe(
        fn -> Resolver.resolve(@central_ref, credential_source: source) end,
        secret,
        :credential_resolver_failed
      )
    end

    missing_source = fn @central_ref -> {:error, {:missing, secret}} end

    assert_secret_safe(
      fn -> Resolver.resolve(@central_ref, credential_source: missing_source) end,
      secret,
      :credential_source_missing
    )
  end

  test "does not expose credential-shaped values in source conflicts or raised text" do
    secret = "credential-shaped-conflict-sentinel"
    source = fn @central_ref -> raise ArgumentError, secret end

    assert_secret_safe(
      fn -> Resolver.resolve(@central_ref, credential_source: source) end,
      secret,
      :credential_resolver_failed
    )
  end

  defp assert_secret_safe(resolve_fun, secret, expected_reason) do
    log =
      capture_log(fn ->
        result = resolve_fun.()
        Logger.error("resolver outcome: #{inspect(result)}")
        send(self(), {:resolver_result, result})
      end)

    assert_receive {:resolver_result, result}
    assert {:error, ^expected_reason} = result
    refute inspect(expected_reason) =~ secret
    refute inspect(result) =~ secret
    refute log =~ secret

    raised_text =
      try do
        raise RuntimeError, inspect(result)
      rescue
        error -> Exception.message(error)
      end

    refute raised_text =~ secret
  end
end
