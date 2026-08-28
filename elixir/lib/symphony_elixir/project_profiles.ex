defmodule SymphonyElixir.ProjectProfiles do
  @moduledoc """
  Parses and validates the versioned, explicitly approved project-profile set.
  """

  @profile_fields ~w(key linear_project_id repository canonical_branch workspace_namespace credential_ref environment)
  @manifest %{
    "central-brain" => %{
      key: "central-brain",
      linear_project_id: "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      repository: "aroakpm-svg/aroak-central-brain",
      canonical_branch: "main",
      workspace_namespace: "central-brain",
      credential_ref: "github-central-brain",
      environment: "local_non_production"
    },
    "project-management" => %{
      key: "project-management",
      linear_project_id: "708053e0-f42c-4e93-bec4-7abbb37e74af",
      repository: "aroakpm-svg/aroak-project-management",
      canonical_branch: "main",
      workspace_namespace: "project-management",
      credential_ref: "github-project-management",
      environment: "local_non_production"
    }
  }

  @type profile :: %{
          key: String.t(),
          linear_project_id: String.t(),
          repository: String.t(),
          canonical_branch: String.t(),
          workspace_namespace: String.t(),
          credential_ref: String.t(),
          environment: String.t()
        }
  @type t :: %{version: 1, profiles: %{required(String.t()) => profile()}}
  @type reason ::
          :invalid_project_profiles
          | :key_collision
          | :unsupported_version
          | :unknown_fields
          | {:missing_profiles, [String.t()]}
          | :unknown_profile
          | {:duplicate_identity, atom()}
          | {:profile_mismatch, String.t(), String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, reason()}
  def parse(raw) do
    with {:ok, %{"version" => version, "profiles" => profiles} = config} <- normalize_keys(raw),
         :ok <- exact_fields(config, ~w(version profiles)),
         :ok <- supported_version(version),
         true <- is_list(profiles),
         {:ok, parsed_profiles} <- parse_profiles(profiles),
         :ok <- complete_profile_set(parsed_profiles) do
      {:ok, %{version: 1, profiles: parsed_profiles}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_project_profiles}
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, profile()} | :error
  def fetch(%{profiles: profiles}, key) when is_map(profiles) and is_binary(key) do
    Map.fetch(profiles, key)
  end

  def fetch(_profiles, _key), do: :error

  @spec list(t()) :: [profile()]
  def list(%{profiles: profiles}) do
    profiles
    |> Map.values()
    |> Enum.sort_by(& &1.key)
  end

  @spec fetch_by_linear_project_id(t(), String.t()) :: {:ok, profile()} | :error
  def fetch_by_linear_project_id(profiles, project_id) do
    case Enum.filter(list(profiles), &(&1.linear_project_id == project_id)) do
      [profile] -> {:ok, profile}
      _ -> :error
    end
  end

  @spec reload(t() | nil, term()) :: {:ok, t()} | {:error, reason(), t() | nil}
  def reload(last_known_good, candidate) do
    case parse(candidate) do
      {:ok, profiles} -> {:ok, profiles}
      {:error, reason} -> {:error, reason, last_known_good}
    end
  end

  defp parse_profiles(profiles) do
    with :ok <- validate_profile_shapes(profiles),
         :ok <- validate_unique_identities(profiles) do
      Enum.reduce_while(profiles, {:ok, %{}}, &put_profile/2)
    end
  end

  defp put_profile(raw_profile, {:ok, parsed}) do
    case parse_profile(raw_profile) do
      {:ok, %{key: key} = profile} -> {:cont, {:ok, Map.put(parsed, key, profile)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_profile_shapes(profiles) do
    Enum.reduce_while(profiles, :ok, fn
      %{} = profile, :ok ->
        case exact_fields(profile, @profile_fields) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _profile, :ok ->
        {:halt, {:error, :invalid_project_profiles}}
    end)
  end

  defp validate_unique_identities(profiles) do
    [
      key: "key",
      linear_project_id: "linear_project_id",
      repository: "repository",
      workspace_namespace: "workspace_namespace",
      credential_ref: "credential_ref"
    ]
    |> Enum.reduce_while(:ok, fn {identity, field}, :ok ->
      values = Enum.map(profiles, &Map.get(&1, field))

      if Enum.uniq(values) == values,
        do: {:cont, :ok},
        else: {:halt, {:error, {:duplicate_identity, identity}}}
    end)
  end

  defp parse_profile(%{} = profile) do
    with :ok <- exact_fields(profile, @profile_fields),
         key when is_binary(key) <- profile["key"],
         {:ok, approved} <- approved_profile(key),
         :ok <- matches_manifest(profile, approved) do
      {:ok, approved}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_project_profiles}
    end
  end

  defp approved_profile(key) do
    case Map.fetch(@manifest, key) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :unknown_profile}
    end
  end

  defp matches_manifest(profile, approved) do
    Enum.reduce_while(@profile_fields, :ok, fn field, :ok ->
      if profile[field] == Map.fetch!(approved, String.to_existing_atom(field)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:profile_mismatch, approved.key, field}}}
      end
    end)
  end

  defp complete_profile_set(profiles) do
    missing = Map.keys(@manifest) -- Map.keys(profiles)

    if missing == [] and map_size(profiles) == map_size(@manifest),
      do: :ok,
      else: {:error, {:missing_profiles, missing}}
  end

  defp exact_fields(map, expected) do
    actual = Map.keys(map)
    unknown = actual -- expected
    missing = expected -- actual

    cond do
      unknown != [] -> {:error, :unknown_fields}
      missing != [] -> {:error, :invalid_project_profiles}
      true -> :ok
    end
  end

  defp supported_version(1), do: :ok
  defp supported_version(_version), do: {:error, :unsupported_version}

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, &normalize_map_entry/2)
  end

  defp normalize_keys(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn nested, {:ok, normalized} ->
      case normalize_keys(nested) do
        {:ok, normalized_nested} -> {:cont, {:ok, [normalized_nested | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_keys(value), do: {:ok, value}

  defp normalize_map_entry({key, nested}, {:ok, normalized}) do
    normalized_key = normalize_key(key)

    with false <- Map.has_key?(normalized, normalized_key),
         {:ok, normalized_nested} <- normalize_keys(nested) do
      {:cont, {:ok, Map.put(normalized, normalized_key, normalized_nested)}}
    else
      true -> {:halt, {:error, :key_collision}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
