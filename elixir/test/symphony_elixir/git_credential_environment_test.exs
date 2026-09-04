defmodule SymphonyElixir.GitCredentialEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitCredentialEnvironment
  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @secret "credential-protocol-secret-sentinel"

  test "invalid or empty credentials never produce an executable Git helper environment" do
    empty = %Credential{credential_ref: "github-central-brain", token: ""}
    missing = %Credential{credential_ref: "github-central-brain", token: nil}

    for credential <- [nil, %{}, empty, missing] do
      assert {:error, :invalid_git_credential} = GitCredentialEnvironment.build(credential)
    end
  end

  test "helper authenticates only HTTPS github.com and ignores ambient helpers" do
    root = Path.join(System.tmp_dir!(), "git-credential-environment-#{System.unique_integer([:positive])}")
    marker = Path.join(root, "ambient-helper.marker")
    global_config = Path.join(root, "ambient.gitconfig")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(global_config, "[credential]\n\thelper = !printf ambient > '#{shell_path(marker)}'\n")

    credential = %Credential{credential_ref: "github-central-brain", token: @secret}
    assert {:ok, environment} = SymphonyElixir.ProjectCredentialProvider.environment(credential)

    environment =
      Map.merge(
        %{"GIT_CONFIG_COUNT" => "0", "GIT_CONFIG_PARAMETERS" => false, "GIT_CONFIG_SYSTEM" => if(match?({:win32, _}, :os.type()), do: "NUL", else: "/dev/null"), "ENV" => false, "BASH_ENV" => false},
        environment
      )
      |> Map.put("HOME", root)
      |> Map.put("GIT_CONFIG_GLOBAL", global_config)
      |> Map.put("GIT_CONFIG_NOSYSTEM", "1")
      |> Map.put("GIT_TERMINAL_PROMPT", "0")
      |> Map.put("GIT_ASKPASS", false)
      |> Map.put("SSH_ASKPASS", false)

    {output, status} = credential_fill("protocol=https\nhost=github.com\n\n", environment)
    assert status == 0
    canonical_username? = String.contains?(output, "username=x-access-token")
    canonical_password? = String.contains?(output, "password=#{@secret}")
    assert canonical_username?
    assert canonical_password?
    refute File.exists?(marker)

    assert {_output, status} = credential_fill("protocol=https\nhost=example.com\n\n", environment)
    assert status != 0
    refute File.exists?(marker)
    refute File.exists?(Path.join(root, ".git-credentials"))
  end

  defp credential_fill(input, environment) do
    encoded = Base.encode64(input)

    System.cmd("sh", ["-c", "printf '%s' '#{encoded}' | base64 -d | git credential fill"],
      cd: System.tmp_dir!(),
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
