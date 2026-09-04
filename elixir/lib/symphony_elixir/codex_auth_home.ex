defmodule SymphonyElixir.CodexAuthHome do
  @moduledoc """
  Resolves a dedicated, operator-provisioned Codex home without reading credentials.

  Only trusted application configuration selects the root. Git and hooks retain their
  issue-private homes; this binding is consumed only by the final Codex launcher.
  """

  alias SymphonyElixir.{Config, PathSafety, ProjectExecutionContext}

  @spec resolve(ProjectExecutionContext.t() | nil) ::
          {:ok, Path.t() | nil} | {:error, :codex_auth_home_unconfigured | :codex_auth_home_invalid}
  def resolve(nil), do: {:ok, nil}

  def resolve(%ProjectExecutionContext{profile_key: profile, workspace_namespace: profile})
      when profile in ["central-brain", "project-management"] do
    case Application.get_env(:symphony_elixir, :codex_auth_home_root) do
      nil -> {:error, :codex_auth_home_unconfigured}
      root -> resolve_home(root, profile)
    end
  end

  def resolve(_context), do: {:error, :codex_auth_home_invalid}

  defp resolve_home(root, profile) when is_binary(root) do
    with true <- String.valid?(root) and not String.contains?(root, [<<0>>, "\n", "\r"]),
         :absolute <- Path.type(root),
         home = Path.join(Path.expand(root), profile),
         true <- safe_directory?(home),
         {:ok, workspace_root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         false <- overlaps?(Path.expand(root), workspace_root),
         true <- Enum.all?(["auth.json", "config.toml"], &safe_optional_file?(Path.join(home, &1))) do
      {:ok, home}
    else
      _invalid -> {:error, :codex_auth_home_invalid}
    end
  end

  defp resolve_home(_root, _profile), do: {:error, :codex_auth_home_invalid}

  defp safe_directory?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(fn component ->
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(component))
    end)
  end

  defp safe_optional_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      {:error, :enoent} -> true
      _unsafe -> false
    end
  end

  defp overlaps?(left, right) do
    left = left |> Path.expand() |> String.downcase() |> String.trim_trailing("/")
    right = right |> Path.expand() |> String.downcase() |> String.trim_trailing("/")
    left == right or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
  end
end
