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
          | {:unsupported_version, term()}
          | {:unknown_fields, [String.t()]}
          | {:missing_profiles, [String.t()]}
          | {:unknown_profile, term()}
          | {:duplicate_identity, atom()}
          | {:profile_mismatch, String.t(), String.t()}

  @spec parse(term()) :: {:ok, t()} | {:error, reason()}
  def parse(raw) do
    with %{"version" => version, "profiles" => profiles} = config <- normalize_keys(raw),
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
      Enum.reduce_while(profiles, {:ok, %{}}, fn raw_profile, {:ok, parsed} ->
        case parse_profile(raw_profile) do
          {:ok, %{key: key} = profile} -> {:cont, {:ok, Map.put(parsed, key, profile)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
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

  defp parse_profile(_profile), do: {:error, :invalid_project_profiles}

  defp approved_profile(key) do
    case Map.fetch(@manifest, key) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unknown_profile, key}}
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
      unknown != [] -> {:error, {:unknown_fields, Enum.sort(unknown)}}
      missing != [] -> {:error, :invalid_project_profiles}
      true -> :ok
    end
  end

  defp supported_version(1), do: :ok
  defp supported_version(version), do: {:error, {:unsupported_version, version}}

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {normalize_key(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
