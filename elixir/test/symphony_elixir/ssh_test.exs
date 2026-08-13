defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok",
               stderr_to_stdout: true,
               command_runner: command_runner(self())
             )

    assert_received {:ssh_command, _executable, ["-T", "-p", "2200", "root@[::1]", "bash -lc 'printf ok'"], [stderr_to_stdout: true]}
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", command_runner: command_runner(self()))

    assert_received {:ssh_command, _executable, ["-T", "::1:2200", "bash -lc 'printf ok'"], []}
  end

  test "run/3 passes host:port targets through ssh -p" do
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
    end)

    config_path = Path.join(System.tmp_dir!(), "symphony-test-ssh-config")
    System.put_env("SYMPHONY_SSH_CONFIG", config_path)

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", command_runner: command_runner(self()))

    assert_received {:ssh_command, _executable, ["-F", ^config_path, "-T", "-p", "2222", "localhost", "bash -lc 'echo ready'"], []}
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", command_runner: command_runner(self()))

    assert_received {:ssh_command, _executable, ["-T", "-p", "2200", "root@127.0.0.1", "bash -lc 'printf ok'"], []}
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
    end)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    fake_port = Port.open({:spawn, windows_noop_command()}, [:exit_status])

    assert {:ok, ^fake_port} =
             SSH.start_port("localhost", "printf ok", port_opener: port_opener(self(), fake_port))

    assert_received {:ssh_port, {:spawn_executable, _executable}, opts}
    assert opts[:args] == Enum.map(["-T", "localhost", "bash -lc 'printf ok'"], &String.to_charlist/1)
    refute Keyword.has_key?(opts, :line)
  end

  test "start_port/3 supports line mode" do
    fake_port = Port.open({:spawn, windows_noop_command()}, [:exit_status])

    assert {:ok, ^fake_port} =
             SSH.start_port("localhost:2222", "printf ok",
               line: 256,
               port_opener: port_opener(self(), fake_port)
             )

    assert_received {:ssh_port, {:spawn_executable, _executable}, opts}
    assert opts[:line] == 256

    assert opts[:args] ==
             Enum.map(["-T", "-p", "2222", "localhost", "bash -lc 'printf ok'"], &String.to_charlist/1)
  end

  test "run/3 uses the configured default command runner" do
    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)
    Application.put_env(:symphony_elixir, :ssh_command_runner, command_runner(self()))
    on_exit(fn -> restore_app_env(:ssh_command_runner, previous_runner) end)

    assert {:ok, {"", 0}} = SSH.run("localhost", "printf ok")
    assert_received {:ssh_command, _executable, ["-T", "localhost", "bash -lc 'printf ok'"], []}
  end

  test "start_port/3 uses the configured default port opener" do
    fake_port = Port.open({:spawn, windows_noop_command()}, [:exit_status])
    previous_opener = Application.get_env(:symphony_elixir, :ssh_port_opener)
    Application.put_env(:symphony_elixir, :ssh_port_opener, port_opener(self(), fake_port))
    on_exit(fn -> restore_app_env(:ssh_port_opener, previous_opener) end)

    assert {:ok, ^fake_port} = SSH.start_port("localhost", "printf ok")
    assert_received {:ssh_port, {:spawn_executable, _executable}, _opts}
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp command_runner(test_pid) do
    fn executable, args, opts ->
      send(test_pid, {:ssh_command, executable, args, opts})
      {"", 0}
    end
  end

  defp port_opener(test_pid, fake_port) do
    fn executable, opts ->
      send(test_pid, {:ssh_port, executable, opts})
      fake_port
    end
  end

  defp windows_noop_command do
    if match?({:win32, _}, :os.type()), do: "cmd /c exit 0", else: "true"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
