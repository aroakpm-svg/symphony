defmodule SymphonyElixir.SubprocessEnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectExecutionContext, SubprocessEnvironment}

  test "project subprocess environment allowlists runtime variables and unsets ambient credentials and node secrets" do
    root =
      Path.join(System.tmp_dir!(), "aro286-subprocess-env-#{System.unique_integer([:positive])}")

    ambient = %{
      "LINEAR_API_KEY" => "linear-secret",
      "NPM_TOKEN" => "npm-secret",
      "NODE_AUTH_TOKEN" => "node-secret",
      "NODE_OPTIONS" => "--require=malicious.js",
      "SSH_AUTH_SOCK" => "ambient-agent.sock",
      "SSH_AGENT_PID" => "4242",
      "GIT_SSH_COMMAND" => "ambient-ssh",
      "GH_CONFIG_DIR" => "ambient-gh",
      "BASH_ENV" => "malicious-profile",
      "ENV" => "malicious-profile"
    }

    previous = Map.new(ambient, fn {key, _value} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf(root)
    end)

    Enum.each(ambient, fn {key, value} -> System.put_env(key, value) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    context = %ProjectExecutionContext{
      issue_id: "issue-aro-286",
      issue_identifier: "ARO-286",
      profile_key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production",
      routing_revision: 1
    }

    assert {:ok, environment} =
             SubprocessEnvironment.build(%{"GH_TOKEN" => "approved-token"}, context)

    assert environment["GH_TOKEN"] == "approved-token"
    assert environment["GITHUB_TOKEN"] == false
    assert environment["LINEAR_API_KEY"] == false
    assert environment["NPM_TOKEN"] == false
    assert environment["NODE_AUTH_TOKEN"] == false
    assert environment["NODE_OPTIONS"] == false
    assert environment["SSH_AUTH_SOCK"] == false
    assert environment["SSH_AGENT_PID"] == false
    assert environment["GIT_SSH_COMMAND"] == false
    assert environment["BASH_ENV"] == false
    assert environment["ENV"] == false
    assert environment["PATH"] == System.get_env("PATH")

    private_home = environment["HOME"]
    assert is_binary(private_home)
    assert private_home != System.user_home!()
    assert environment["USERPROFILE"] == private_home
    assert environment["GH_CONFIG_DIR"] == Path.join(private_home, "gh")

    assert private_home ==
             Path.join([
               Path.expand(root),
               "central-brain",
               ".symphony-subprocess",
               "ARO-286-r1"
             ])

    refute File.exists?(root)
    refute File.exists?(private_home)
    refute File.exists?(environment["GH_CONFIG_DIR"])
    refute File.exists?(environment["CODEX_HOME"])
  end

  test "environment key merging is case-insensitive only on Windows" do
    layers = [
      %{"HOME" => "first", "GH_TOKEN" => false},
      %{"home" => "second", "gh_token" => "later"}
    ]

    assert SubprocessEnvironment.merge_layers_for_test(layers, {:unix, :linux}) == %{
             "GH_TOKEN" => false,
             "HOME" => "first",
             "gh_token" => "later",
             "home" => "second"
           }

    windows = SubprocessEnvironment.merge_layers_for_test(layers, {:win32, :nt})
    assert map_size(windows) == 2
    assert windows["home"] == "second"
    assert windows["gh_token"] == "later"
  end

  test "Windows spawned child receives one canonical private and provider key despite mixed-case ambient names" do
    if match?({:win32, _name}, :os.type()) do
      root =
        Path.join(
          System.tmp_dir!(),
          "aro286-windows-env-case-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      keys = ["HOME", "GH_CONFIG_DIR", "CODEX_HOME", "GH_TOKEN"]
      previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

      on_exit(fn ->
        Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
        File.rm_rf(root)
      end)

      System.put_env("home", "ambient-home")
      System.put_env("Gh_Config_Dir", "ambient-gh")
      System.put_env("CoDeX_HoMe", "ambient-codex")
      System.put_env("gH_ToKeN", "ambient-token")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      context = %ProjectExecutionContext{
        issue_id: "issue-aro-286-case",
        issue_identifier: "ARO-286-CASE",
        profile_key: "central-brain",
        linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
        repository: "aroakpm-svg/aroak-central-brain",
        canonical_branch: "main",
        workspace_namespace: "central-brain",
        credential_ref: "github-central-brain",
        environment: "local_non_production",
        routing_revision: 1
      }

      assert {:ok, environment} =
               SubprocessEnvironment.build(
                 %{
                   "GH_TOKEN" => "approved-token",
                   "gh_token" => "unapproved-token",
                   "home" => "provider-home"
                 },
                 context
               )

      for key <- ["HOME", "GH_CONFIG_DIR", "CODEX_HOME", "GH_TOKEN"] do
        assert 1 ==
                 Enum.count(environment, fn {candidate, _value} ->
                   String.downcase(candidate) == String.downcase(key)
                 end)
      end

      powershell =
        Path.join([
          System.fetch_env!("SystemRoot"),
          "System32",
          "WindowsPowerShell",
          "v1.0",
          "powershell.exe"
        ])

      script = """
      $environment = [Environment]::GetEnvironmentVariables()
      $result = [ordered]@{}
      foreach ($name in @('HOME', 'GH_CONFIG_DIR', 'CODEX_HOME', 'GH_TOKEN')) {
        $matches = @($environment.Keys | Where-Object {
          [string]::Equals([string]$_, $name, [StringComparison]::OrdinalIgnoreCase)
        })
        $result[$name] = [ordered]@{
          count = $matches.Count
          value = [Environment]::GetEnvironmentVariable($name)
        }
      }
      [Console]::Out.Write(($result | ConvertTo-Json -Compress))
      """

      child_environment =
        Enum.map(environment, fn
          {key, false} -> {key, nil}
          entry -> entry
        end)

      assert {output, 0} =
               System.cmd(
                 powershell,
                 ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                 env: child_environment,
                 stderr_to_stdout: true
               )

      decoded = Jason.decode!(output)
      assert decoded["HOME"] == %{"count" => 1, "value" => environment["HOME"]}

      assert decoded["GH_CONFIG_DIR"] == %{
               "count" => 1,
               "value" => environment["GH_CONFIG_DIR"]
             }

      assert decoded["CODEX_HOME"] == %{
               "count" => 1,
               "value" => environment["CODEX_HOME"]
             }

      assert decoded["GH_TOKEN"] == %{"count" => 1, "value" => "approved-token"}
    else
      assert true
    end
  end
end
