defmodule SymphonyElixir.GitHubAppCredentialSourceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHubAppCredentialSource

  test "mints a fresh token narrowed to the credential reference repository" do
    key_path = write_private_key!()
    parent = self()

    request = fn options ->
      send(parent, {:request, options})
      {:ok, %{status: 201, body: %{"token" => "installation-token", "expires_at" => "2030-01-01T00:00:00Z"}}}
    end

    assert {:ok, %{credential_ref: "github-central-brain", token: "installation-token", expires_at: expires_at}} =
             GitHubAppCredentialSource.resolve("github-central-brain", valid_options(key_path, request))

    assert expires_at == ~U[2030-01-01 00:00:00Z]
    assert_receive {:request, options}
    assert options[:url] == "https://api.github.com/app/installations/456/access_tokens"
    assert options[:json] == %{repositories: ["aroak-central-brain"]}
    assert [{"authorization", "Bearer " <> jwt}] = Enum.filter(options[:headers], &(elem(&1, 0) == "authorization"))
    assert length(String.split(jwt, ".")) == 3
  end

  test "uses the exact project-management repository and does not cache tokens" do
    key_path = write_private_key!()
    counter = start_supervised!({Agent, fn -> 0 end})

    request = fn _options ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      {:ok, %{status: 201, body: %{"token" => "token-#{value}", "expires_at" => "2030-01-01T00:00:00Z"}}}
    end

    opts = valid_options(key_path, request)
    assert {:ok, %{token: "token-1"}} = GitHubAppCredentialSource.resolve("github-project-management", opts)
    assert {:ok, %{token: "token-2"}} = GitHubAppCredentialSource.resolve("github-project-management", opts)
    assert Agent.get(counter, & &1) == 2
  end

  test "fails closed without exposing configuration or response details" do
    key_path = write_private_key!()
    secret = "private-response-secret"

    for {ref, opts} <- [
          {"github-unknown", valid_options(key_path, fn _ -> flunk("request made") end)},
          {"github-central-brain", Keyword.delete(valid_options(key_path, fn _ -> flunk("request made") end), :app_id)},
          {"github-central-brain", valid_options(key_path, fn _ -> {:ok, %{status: 401, body: secret}} end)},
          {"github-central-brain", valid_options(key_path, fn _ -> {:ok, %{status: 201, body: %{"token" => secret}}} end)}
        ] do
      result = GitHubAppCredentialSource.resolve(ref, opts)
      assert result == {:error, :failed}
      refute inspect(result) =~ secret
      refute inspect(result) =~ key_path
    end
  end

  test "preserves retryability for transport, throttling, and server failures" do
    key_path = write_private_key!()

    for response <- [
          {:error, :timeout},
          {:error, :nxdomain},
          {:ok, %{status: 408, body: "secret"}},
          {:ok, %{status: 429, body: "secret"}},
          {:ok, %{status: 500, body: "secret"}},
          {:ok, %{status: 599, body: "secret"}},
          {:ok, %{status: 403, headers: %{"x-ratelimit-remaining" => "0"}, body: "secret"}},
          {:ok, %{status: 403, headers: %{"retry-after" => "1"}, body: "secret"}},
          {:ok, %{status: 403, body: %{"message" => "You have exceeded a secondary rate limit"}}}
        ] do
      assert {:error, :unavailable} =
               GitHubAppCredentialSource.resolve(
                 "github-central-brain",
                 valid_options(key_path, fn _ -> response end)
               )
    end

    assert {:error, :failed} =
             GitHubAppCredentialSource.resolve(
               "github-central-brain",
               valid_options(key_path, fn _ -> {:ok, %{status: 600, body: "secret"}} end)
             )

    assert {:error, :failed} =
             GitHubAppCredentialSource.resolve(
               "github-central-brain",
               valid_options(key_path, fn _ -> {:ok, %{status: 403, body: "forbidden"}} end)
             )
  end

  test "explicit configuration retains only the module and expected actor" do
    key_path = write_private_key!()
    previous_source = Application.get_env(:symphony_elixir, :github_credential_source)
    previous_opts = Application.get_env(:symphony_elixir, :orchestrator_opts)
    keys = runtime_environment(key_path)
    previous_env = Map.new(keys, fn {key, _value} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      restore_application_env(:github_credential_source, previous_source)
      restore_application_env(:orchestrator_opts, previous_opts)
      Enum.each(previous_env, fn {key, value} -> restore_system_env(key, value) end)
    end)

    Application.delete_env(:symphony_elixir, :github_credential_source)
    Application.put_env(:symphony_elixir, :orchestrator_opts, poll_interval: 123)
    Enum.each(keys, fn {key, value} -> System.put_env(key, value) end)

    assert :ok = GitHubAppCredentialSource.configure()
    assert Application.get_env(:symphony_elixir, :github_credential_source) == GitHubAppCredentialSource

    assert Application.get_env(:symphony_elixir, :orchestrator_opts) ==
             [expected_actor: "aroak-symphony[bot]", poll_interval: 123]

    refute inspect(Application.get_all_env(:symphony_elixir)) =~ key_path
  end

  test "runtime resolution and exceptional callbacks fail closed" do
    key_path = write_private_key!()
    keys = runtime_environment(key_path)
    previous_env = Map.new(keys, fn {key, _value} -> {key, System.get_env(key)} end)
    on_exit(fn -> Enum.each(previous_env, fn {key, value} -> restore_system_env(key, value) end) end)
    Enum.each(keys, fn {key, value} -> System.put_env(key, value) end)
    File.rm!(key_path)

    assert {:error, :failed} = GitHubAppCredentialSource.resolve("github-central-brain")

    key_path = write_private_key!()

    assert {:error, :failed} =
             GitHubAppCredentialSource.resolve(
               "github-central-brain",
               valid_options(key_path, fn _ -> raise "secret" end)
             )

    assert {:error, :failed} =
             GitHubAppCredentialSource.resolve(
               "github-central-brain",
               valid_options(key_path, fn _ -> throw(:secret) end)
             )
  end

  test "rejects invalid option types and identifiers" do
    key_path = write_private_key!()
    request = fn _ -> flunk("request made") end

    successful_request = fn _ ->
      {:ok, %{status: 201, body: %{"token" => "token", "expires_at" => "2030-01-01T00:00:00Z"}}}
    end

    assert {:ok, %{token: "token"}} =
             GitHubAppCredentialSource.resolve(
               "github-central-brain",
               Keyword.put(valid_options(key_path, successful_request), :app_id, 123)
             )

    for opts <- [
          Keyword.put(valid_options(key_path, request), :app_id, "bad"),
          Keyword.put(valid_options(key_path, request), :installation_id, "0"),
          Keyword.put(valid_options(key_path, request), :now, :invalid),
          Keyword.put(valid_options(key_path, request), :private_key_path, nil),
          Keyword.put(valid_options(key_path, request), :request_fun, :invalid)
        ] do
      assert {:error, :failed} = GitHubAppCredentialSource.resolve("github-central-brain", opts)
    end

    assert {:error, :failed} = GitHubAppCredentialSource.resolve(:invalid, %{})
  end

  test "explicit configuration rejects competing persistent settings" do
    key_path = write_private_key!()
    keys = runtime_environment(key_path)
    previous_source = Application.get_env(:symphony_elixir, :github_credential_source)
    previous_opts = Application.get_env(:symphony_elixir, :orchestrator_opts)
    previous_env = Map.new(keys, fn {key, _value} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      restore_application_env(:github_credential_source, previous_source)
      restore_application_env(:orchestrator_opts, previous_opts)
      Enum.each(previous_env, fn {key, value} -> restore_system_env(key, value) end)
    end)

    Enum.each(keys, fn {key, value} -> System.put_env(key, value) end)
    Application.put_env(:symphony_elixir, :github_credential_source, __MODULE__)
    assert {:error, :github_app_configuration_invalid} = GitHubAppCredentialSource.configure()

    Application.put_env(:symphony_elixir, :github_credential_source, GitHubAppCredentialSource)
    Application.put_env(:symphony_elixir, :orchestrator_opts, expected_actor: "other[bot]")
    assert {:error, :github_app_configuration_invalid} = GitHubAppCredentialSource.configure()

    Application.put_env(:symphony_elixir, :orchestrator_opts, %{invalid: true})
    assert {:error, :github_app_configuration_invalid} = GitHubAppCredentialSource.configure()

    Application.put_env(:symphony_elixir, :orchestrator_opts, [:invalid])
    assert {:error, :github_app_configuration_invalid} = GitHubAppCredentialSource.configure()

    Application.put_env(:symphony_elixir, :orchestrator_opts, [])
    assert :ok = GitHubAppCredentialSource.configure()

    Application.put_env(:symphony_elixir, :orchestrator_opts, expected_actor: "aroak-symphony[bot]")
    assert :ok = GitHubAppCredentialSource.configure()

    File.write!(key_path, "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n")
    assert {:error, :github_app_configuration_invalid} = GitHubAppCredentialSource.configure()
  end

  defp valid_options(key_path, request) do
    [app_id: "123", installation_id: "456", private_key_path: key_path, request_fun: request, now: ~U[2026-09-07 00:00:00Z]]
  end

  defp runtime_environment(key_path) do
    %{
      "SYMPHONY_GITHUB_APP_ID" => "123",
      "SYMPHONY_GITHUB_APP_INSTALLATION_ID" => "456",
      "SYMPHONY_GITHUB_APP_EXPECTED_ACTOR" => "aroak-symphony[bot]",
      "SYMPHONY_GITHUB_APP_PRIVATE_KEY_FILE" => key_path,
      "SYMPHONY_ADMISSION_PAUSE_FILE" => key_path <> ".pause"
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp write_private_key! do
    path = Path.join(System.tmp_dir!(), "symphony-app-key-#{System.unique_integer([:positive])}.pem")
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    File.write!(path, pem)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
