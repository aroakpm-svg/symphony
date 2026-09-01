defmodule SymphonyElixir.SubprocessEnvironment do
  @moduledoc """
  Builds a context-scoped, deny-by-default environment for hooks, Git, and Codex.
  """

  alias SymphonyElixir.{Config, ProjectExecutionContext}

  @runtime_keys ~w(
    PATH PATHEXT SystemRoot SYSTEMROOT WINDIR COMSPEC
    TEMP TMP TMPDIR LANG LC_ALL LC_CTYPE TERM TZ SOURCE_REPO_URL
  )
  @provider_keys MapSet.new([
                   "GH_TOKEN",
                   "GITHUB_TOKEN",
                   "GIT_ASKPASS",
                   "SSH_ASKPASS",
                   "GIT_SSH_COMMAND",
                   "SSH_AUTH_SOCK",
                   "SSH_AGENT_PID",
                   "GIT_CONFIG_PARAMETERS",
                   "GIT_CONFIG_COUNT"
                 ])

  @type value :: String.t() | false
  @type t :: %{optional(String.t()) => value()}
  @type private_home_paths :: %{
          root: Path.t(),
          home: Path.t(),
          gh: Path.t(),
          xdg_config: Path.t(),
          xdg_cache: Path.t(),
          xdg_data: Path.t(),
          codex: Path.t()
        }

  @spec build(map(), ProjectExecutionContext.t()) :: {:ok, t()}
  def build(provider_environment, %ProjectExecutionContext{} = context)
      when is_map(provider_environment) do
    paths = private_home_paths(context)
    runtime_key_set = MapSet.new(Enum.map(@runtime_keys, &String.upcase/1))

    ambient_unsets =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> valid_environment_key?(key) end)
      |> Map.new(fn {key, value} ->
        if MapSet.member?(runtime_key_set, String.upcase(key)),
          do: {key, value},
          else: {key, false}
      end)

    runtime_environment =
      Map.new(@runtime_keys, fn key -> {key, System.get_env(key)} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    environment =
      merge_environment_layers(
        [
          ambient_unsets,
          runtime_environment,
          credential_defaults(),
          approved_provider_environment(provider_environment),
          isolated_home_environment(paths)
        ],
        :os.type()
      )

    {:ok, environment}
  end

  @spec private_home_paths(ProjectExecutionContext.t()) :: private_home_paths()
  def private_home_paths(%ProjectExecutionContext{} = context) do
    issue_leaf = safe_path_segment(context.issue_identifier)
    workspace_root = Path.expand(Config.settings!().workspace.root)

    root =
      Path.join([
        workspace_root,
        context.workspace_namespace,
        ".symphony-subprocess"
      ])

    home = Path.join(root, "#{issue_leaf}-r#{context.routing_revision}")

    %{
      root: root,
      home: home,
      gh: Path.join(home, "gh"),
      xdg_config: Path.join(home, "xdg-config"),
      xdg_cache: Path.join(home, "xdg-cache"),
      xdg_data: Path.join(home, "xdg-data"),
      codex: Path.join(home, "codex")
    }
  end

  defp credential_defaults do
    %{
      "GH_TOKEN" => false,
      "GITHUB_TOKEN" => false,
      "GIT_ASKPASS" => false,
      "SSH_ASKPASS" => false,
      "GIT_SSH_COMMAND" => false,
      "SSH_AUTH_SOCK" => false,
      "SSH_AGENT_PID" => false,
      "GCM_INTERACTIVE" => "Never",
      "GIT_CONFIG_COUNT" => "0",
      "GIT_CONFIG_GLOBAL" => git_null_device(),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_PARAMETERS" => "'credential.helper='",
      "GIT_CONFIG_SYSTEM" => git_null_device(),
      "GIT_TERMINAL_PROMPT" => "0"
    }
  end

  @doc false
  @spec merge_layers_for_test([map()], {:unix | :win32, atom()}) :: map()
  def merge_layers_for_test(layers, platform) when is_list(layers),
    do: merge_environment_layers(layers, platform)

  defp merge_environment_layers(layers, {:win32, _name}) do
    layers
    |> Enum.reduce(%{}, fn layer, environment ->
      Enum.reduce(layer, environment, fn {key, value}, accumulator ->
        Map.put(accumulator, String.downcase(key), {key, value})
      end)
    end)
    |> Map.values()
    |> Map.new()
  end

  defp merge_environment_layers(layers, {:unix, _name}) do
    Enum.reduce(layers, %{}, &Map.merge(&2, &1))
  end

  defp approved_provider_environment(environment) do
    Map.new(environment, fn {key, value} -> {key, value} end)
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_binary(value) and approved_provider_key?(key)
    end)
    |> Map.new()
  end

  defp approved_provider_key?(key) do
    MapSet.member?(@provider_keys, key) or
      Regex.match?(~r/^GIT_CONFIG_(?:KEY|VALUE)_\d+$/, key)
  end

  defp valid_environment_key?(key) do
    is_binary(key) and key != "" and not String.contains?(key, ["=", <<0>>])
  end

  defp isolated_home_environment(paths) do
    %{
      "HOME" => paths.home,
      "USERPROFILE" => paths.home,
      "GH_CONFIG_DIR" => paths.gh,
      "XDG_CONFIG_HOME" => paths.xdg_config,
      "XDG_CACHE_HOME" => paths.xdg_cache,
      "XDG_DATA_HOME" => paths.xdg_data,
      "CODEX_HOME" => paths.codex
    }
  end

  defp safe_path_segment(value) do
    String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp git_null_device do
    if match?({:win32, _}, :os.type()), do: "NUL", else: "/dev/null"
  end
end
