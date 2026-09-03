defmodule SymphonyElixir.GitCredentialEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitCredentialEnvironment
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @secret "credential-protocol-secret-sentinel"

  test "helper authenticates only HTTPS github.com and ignores ambient helpers" do
    root = Path.join(System.tmp_dir!(), "git-credential-environment-#{System.unique_integer([:positive])}")
    marker = Path.join(root, "ambient-helper.marker")
    global_config = Path.join(root, "ambient.gitconfig")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(global_config, "[credential]\n\thelper = !printf ambient > '#{shell_path(marker)}'\n")

    credential = %Credential{credential_ref: "github-central-brain", token: @secret}
    assert {:ok, environment} = GitCredentialEnvironment.build(credential)
    environment = environment |> Map.put("HOME", root) |> Map.put("GIT_CONFIG_GLOBAL", global_config)

    assert {output, 0} = credential_fill("protocol=https\nhost=github.com\n\n", environment)
    assert output =~ "username=x-access-token"
    assert output =~ "password=#{@secret}"
    refute File.exists?(marker)

    assert {_output, status} = credential_fill("protocol=https\nhost=example.com\n\n", environment)
    assert status != 0
    refute File.exists?(marker)
    refute File.exists?(Path.join(root, ".git-credentials"))
  end

  defp credential_fill(input, environment) do
    encoded = Base.encode64(input)

    System.cmd("sh", ["-c", "printf '%s' '#{encoded}' | base64 -d | git credential fill"],
      env:
        Enum.map(environment, fn
          {key, false} -> {key, nil}
          entry -> entry
        end),
      stderr_to_stdout: true
    )
  end

  defp shell_path(path), do: String.replace(path, "\\", "/")
end
