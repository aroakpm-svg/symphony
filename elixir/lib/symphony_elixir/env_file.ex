defmodule SymphonyElixir.EnvFile do
  @moduledoc false

  @spec load_local(Path.t()) :: :ok
  def load_local(workflow_path) when is_binary(workflow_path) do
    workflow_path
    |> Path.dirname()
    |> candidate_paths()
    |> Enum.find(&File.regular?/1)
    |> load_file()
  end

  defp candidate_paths(dir) do
    [
      Path.join(dir, ".env.local"),
      Path.join(dir, ".env.local.txt")
    ]
  end

  defp load_file(nil), do: :ok

  defp load_file(path) do
    lines = File.stream!(path, :line, []) |> Enum.to_list()
    env_assignment? = Enum.reduce(lines, false, fn line, found? -> put_env_line(line) or found? end)

    if env_assignment? do
      :ok
    else
      put_raw_linear_api_key(lines)
    end
  end

  defp put_env_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        false

      true ->
        line
        |> String.replace_prefix("export ", "")
        |> String.split("=", parts: 2)
        |> put_env_pair()
    end
  end

  defp put_env_pair([key, value]) do
    key = String.trim(key)

    if valid_key?(key) and is_nil(System.get_env(key)) do
      System.put_env(key, normalize_value(value))
      true
    else
      false
    end
  end

  defp put_env_pair(_line), do: false

  defp put_raw_linear_api_key(lines) do
    raw_value =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))

    if is_binary(raw_value) and is_nil(System.get_env("LINEAR_API_KEY")) do
      System.put_env("LINEAR_API_KEY", normalize_value(raw_value))
    end

    :ok
  end

  defp valid_key?(key), do: String.match?(key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp normalize_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end
