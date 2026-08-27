defmodule SymphonyElixir.ProjectProfilesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectProfiles
  alias SymphonyElixir.Config.Schema.ProjectProfilesType

  test "parses the complete approved v1 profile set and supports exact lookup" do
    assert {:ok, profiles} = ProjectProfiles.parse(valid_config())

    assert {:ok, central} = ProjectProfiles.fetch(profiles, "central-brain")
    assert central.repository == "aroakpm-svg/aroak-central-brain"

    assert {:ok, project_management} =
             ProjectProfiles.fetch(profiles, "project-management")

    assert project_management.linear_project_id ==
             "708053e0-f42c-4e93-bec4-7abbb37e74af"

    assert :error = ProjectProfiles.fetch(profiles, "unknown")
  end

  test "rejects unsupported versions, incomplete sets, and unknown fields" do
    assert {:error, {:unsupported_version, 2}} =
             valid_config()
             |> Map.put("version", 2)
             |> ProjectProfiles.parse()

    assert {:error, {:missing_profiles, ["project-management"]}} =
             valid_config()
             |> put_in(["profiles"], [central_profile()])
             |> ProjectProfiles.parse()

    assert {:error, {:unknown_fields, ["slots"]}} =
             valid_config()
             |> Map.put("slots", 3)
             |> ProjectProfiles.parse()

    assert {:error, {:unknown_fields, ["total_slots"]}} =
             valid_config()
             |> update_in(["profiles", Access.at(0)], &Map.put(&1, "total_slots", 3))
             |> ProjectProfiles.parse()
  end

  test "rejects duplicate profile identities before manifest approval" do
    duplicate_key = [central_profile(), central_profile()]

    assert {:error, {:duplicate_identity, :key}} =
             ProjectProfiles.parse(%{"version" => 1, "profiles" => duplicate_key})

    for {field, identity} <- [
          {"linear_project_id", :linear_project_id},
          {"repository", :repository},
          {"workspace_namespace", :workspace_namespace},
          {"credential_ref", :credential_ref}
        ] do
      duplicate_value = central_profile()[field]

      config =
        update_in(valid_config(), ["profiles", Access.at(1)], fn profile ->
          Map.put(profile, field, duplicate_value)
        end)

      assert {:error, {:duplicate_identity, ^identity}} = ProjectProfiles.parse(config)
    end
  end

  test "rejects unknown projects and authority-bearing manifest drift without echoing values" do
    unknown = Map.put(central_profile(), "key", "other")

    assert {:error, {:unknown_profile, "other"}} =
             ProjectProfiles.parse(%{"version" => 1, "profiles" => [unknown, project_management_profile()]})

    for {field, unsafe_value} <- [
          {"linear_project_id", "wrong-project"},
          {"repository", "aroakpm-svg/wrong"},
          {"canonical_branch", "develop"},
          {"workspace_namespace", "../escape"},
          {"credential_ref", "token=must-not-escape"},
          {"environment", "production"}
        ] do
      config =
        update_in(valid_config(), ["profiles", Access.at(0)], fn profile ->
          Map.put(profile, field, unsafe_value)
        end)

      assert {:error, {:profile_mismatch, "central-brain", ^field}} =
               ProjectProfiles.parse(config)

      refute inspect(ProjectProfiles.parse(config)) =~ "token=must-not-escape"
    end
  end

  test "reload replaces only with a complete valid set and otherwise retains last-known-good" do
    assert {:ok, first} = ProjectProfiles.reload(nil, valid_config())
    assert {:ok, ^first} = ProjectProfiles.reload(first, valid_config())

    invalid = Map.put(valid_config(), "version", 2)

    assert {:error, {:unsupported_version, 2}, ^first} =
             ProjectProfiles.reload(first, invalid)

    assert {:error, {:unsupported_version, 2}, nil} =
             ProjectProfiles.reload(nil, invalid)
  end

  test "rejects malformed shapes and supports atom-keyed workflow input" do
    assert {:error, :invalid_project_profiles} = ProjectProfiles.parse(nil)
    assert {:error, :invalid_project_profiles} = ProjectProfiles.parse(%{"version" => 1, "profiles" => "nope"})

    assert {:error, :invalid_project_profiles} =
             ProjectProfiles.parse(%{"version" => 1, "profiles" => [nil]})

    non_binary_key = Map.put(central_profile(), "key", 42)

    assert {:error, :invalid_project_profiles} =
             ProjectProfiles.parse(%{"version" => 1, "profiles" => [non_binary_key]})

    assert :error = ProjectProfiles.fetch(nil, "central-brain")

    atom_config = %{
      version: 1,
      profiles: [
        Map.new(central_profile(), fn {key, value} -> {String.to_existing_atom(key), value} end),
        Map.new(project_management_profile(), fn {key, value} -> {String.to_existing_atom(key), value} end)
      ]
    }

    assert {:ok, _profiles} = ProjectProfiles.parse(atom_config)
  end

  test "Ecto type callbacks cover every safe rejection without echoing submitted values" do
    assert ProjectProfilesType.type() == :map
    assert ProjectProfilesType.embed_as(:json) == :self
    assert ProjectProfilesType.equal?(%{a: 1}, %{a: 1})
    refute ProjectProfilesType.equal?(%{a: 1}, %{a: 2})
    assert {:ok, %{a: 1}} = ProjectProfilesType.load(%{a: 1})
    assert :error = ProjectProfilesType.load("invalid")
    assert {:ok, %{a: 1}} = ProjectProfilesType.dump(%{a: 1})
    assert :error = ProjectProfilesType.dump("invalid")

    invalid_candidates = [
      nil,
      Map.put(valid_config(), "version", "secret-version"),
      Map.put(valid_config(), "secret-field", "secret-value"),
      Map.put(valid_config(), "profiles", [central_profile()]),
      Map.put(valid_config(), "profiles", [Map.put(central_profile(), "key", "secret-profile")]),
      Map.put(valid_config(), "profiles", [central_profile(), central_profile()]),
      update_in(valid_config(), ["profiles", Access.at(0)], &Map.put(&1, "credential_ref", "secret-token"))
    ]

    for candidate <- invalid_candidates do
      assert {:error, message: message} = ProjectProfilesType.cast(candidate)
      refute message =~ "secret"
    end
  end

  defp valid_config do
    %{
      "version" => 1,
      "profiles" => [central_profile(), project_management_profile()]
    }
  end

  defp central_profile do
    %{
      "key" => "central-brain",
      "linear_project_id" => "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
      "repository" => "aroakpm-svg/aroak-central-brain",
      "canonical_branch" => "main",
      "workspace_namespace" => "central-brain",
      "credential_ref" => "github-central-brain",
      "environment" => "local_non_production"
    }
  end

  defp project_management_profile do
    %{
      "key" => "project-management",
      "linear_project_id" => "708053e0-f42c-4e93-bec4-7abbb37e74af",
      "repository" => "aroakpm-svg/aroak-project-management",
      "canonical_branch" => "main",
      "workspace_namespace" => "project-management",
      "credential_ref" => "github-project-management",
      "environment" => "local_non_production"
    }
  end
end
