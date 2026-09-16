defmodule SymphonyElixir.ProtectedPathTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProtectedPath

  @controller "S-1-5-21-1000"
  @system "S-1-5-18"
  @administrators "S-1-5-32-544"
  @trusted_installer "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
  @broker_service "S-1-5-80-111-222-333-444-555"
  @users "S-1-5-32-545"
  @authenticated_users "S-1-5-11"
  @base_acl "user::rw-\ngroup::---\nother::---\n"

  test "POSIX ACL evidence rejects named and default grants" do
    assert :ok =
             ProtectedPath.validate_posix_acl_output("""
             user::rw-
             group::---
             other::---
             """)

    for output <- [
          "user::rw-\nuser:2000:r--\ngroup::---\nmask::r--\nother::---\n",
          "user::rwx\ngroup::---\nother::---\ndefault:user::rwx\n"
        ] do
      assert {:error, :unsafe_protected_path} =
               ProtectedPath.validate_posix_acl_output(output)
    end

    assert {:error, :unsafe_protected_path} = ProtectedPath.validate_posix_acl_output(:invalid)
  end

  test "POSIX directory evidence binds controller ownership and protected modes" do
    controller = 1_000
    private = %File.Stat{type: :directory, uid: controller, mode: 0o700}
    root_ancestor = %File.Stat{type: :directory, uid: 0, mode: 0o755}

    assert :ok =
             ProtectedPath.validate_posix_directory_evidence(
               private,
               controller,
               0o700,
               :controller,
               @base_acl
             )

    assert :ok =
             ProtectedPath.validate_posix_directory_evidence(
               root_ancestor,
               controller,
               nil,
               :trusted,
               @base_acl
             )

    for unsafe <- [
          %{private | uid: 0},
          %{private | mode: 0o750},
          %{root_ancestor | uid: controller + 1},
          %{root_ancestor | mode: 0o775}
        ] do
      assert {:error, :unsafe_protected_path} =
               ProtectedPath.validate_posix_directory_evidence(
                 unsafe,
                 controller,
                 0o700,
                 :controller,
                 @base_acl
               )
    end

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_posix_directory_evidence(
               :not_a_stat,
               controller,
               0o700,
               :controller,
               @base_acl
             )
  end

  test "POSIX gate and secret evidence apply distinct integrity and secrecy policies" do
    controller = 1_000

    assert :ok =
             ProtectedPath.validate_posix_gate_evidence(
               %File.Stat{type: :regular, uid: 0, mode: 0o644},
               controller,
               @base_acl
             )

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_posix_gate_evidence(
               %File.Stat{type: :regular, uid: controller, mode: 0o664},
               controller,
               @base_acl
             )

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_posix_gate_evidence(:not_a_stat, controller, @base_acl)

    assert :ok =
             ProtectedPath.validate_posix_secret_evidence(
               %File.Stat{type: :regular, uid: controller, mode: 0o600},
               controller,
               @base_acl
             )

    for unsafe <- [
          %File.Stat{type: :regular, uid: 0, mode: 0o600},
          %File.Stat{type: :regular, uid: controller, mode: 0o640}
        ] do
      assert {:error, :unsafe_protected_path} =
               ProtectedPath.validate_posix_secret_evidence(unsafe, controller, @base_acl)
    end
  end

  test "Windows secret ACL rejects service SIDs even for a LocalSystem controller" do
    evidence =
      windows_evidence(@system, true, [
        allow_rule(@system, 0x1F01FF),
        allow_rule(@administrators, 0x1F01FF),
        allow_rule(@broker_service, 0x000001)
      ])

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_windows_acl_evidence(evidence, :secret_entry, @system)
  end

  test "Windows secret parent must be controller-owned and protected" do
    safe =
      windows_evidence(@controller, true, [
        allow_rule(@controller, 0x1F01FF),
        allow_rule(@system, 0x1F01FF),
        allow_rule(@administrators, 0x1F01FF)
      ])

    assert :ok = ProtectedPath.validate_windows_acl_evidence(safe, :secret_parent, @controller)

    assert {:error, :unsafe_protected_path} =
             safe
             |> Map.put("owner", @administrators)
             |> ProtectedPath.validate_windows_acl_evidence(:secret_parent, @controller)

    assert {:error, :unsafe_protected_path} =
             safe
             |> Map.put("protected", false)
             |> ProtectedPath.validate_windows_acl_evidence(:secret_parent, @controller)

    assert {:error, :unsafe_protected_path} =
             safe
             |> Map.put("daclPresent", false)
             |> ProtectedPath.validate_windows_acl_evidence(:secret_parent, @controller)
  end

  test "Windows higher ancestors allow traverse but reject path takeover rights" do
    harmless =
      windows_evidence(@system, false, [
        allow_rule(@users, 0x000020),
        allow_rule(@users, 0x1200A9),
        allow_rule(@users, 0x000004),
        allow_rule(@users, 0x80000000),
        allow_rule(@users, 0x20000000)
      ])

    assert :ok = ProtectedPath.validate_windows_acl_evidence(harmless, :ancestor, @controller)

    for rights <- [0x010040, 0x10000000, 0x40000000, 0x04000000] do
      dangerous = windows_evidence(@system, false, [allow_rule(@users, rights)])

      assert {:error, :unsafe_protected_path} =
               ProtectedPath.validate_windows_acl_evidence(dangerous, :ancestor, @controller)
    end
  end

  test "Windows higher ancestor accepts exact TrustedInstaller and ignores inherit-only grants" do
    root_evidence =
      windows_evidence(@trusted_installer, false, [
        allow_rule(@trusted_installer, 0x1F01FF),
        allow_rule(@authenticated_users, 0x000004),
        allow_rule(@authenticated_users, 0xE0010000,
          inheritance_flags: 3,
          propagation_flags: 2
        )
      ])

    assert :ok =
             ProtectedPath.validate_windows_acl_evidence(
               root_evidence,
               :ancestor,
               @controller
             )

    applicable =
      windows_evidence(@trusted_installer, false, [
        allow_rule(@authenticated_users, 0xE0010000)
      ])

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_windows_acl_evidence(applicable, :ancestor, @controller)

    assert {:error, :unsafe_protected_path} =
             ProtectedPath.validate_windows_acl_evidence(
               root_evidence,
               :gate_parent,
               @controller
             )
  end

  test "Windows ACL evidence validates deny and malformed rules and SIDs" do
    deny_only =
      windows_evidence(@controller, true, [
        deny_rule(@users, 1)
      ])

    assert :ok =
             ProtectedPath.validate_windows_acl_evidence(deny_only, :secret_entry, @controller)

    for evidence <- [
          windows_evidence(@controller, true, [%{}]),
          windows_evidence(@controller, true, [allow_rule(123, 1)])
        ] do
      assert {:error, :unsafe_protected_path} =
               ProtectedPath.validate_windows_acl_evidence(evidence, :secret_entry, @controller)
    end
  end

  defp windows_evidence(owner, protected, rules) do
    %{"owner" => owner, "protected" => protected, "daclPresent" => true, "rules" => rules}
  end

  defp allow_rule(sid, rights, opts \\ []) do
    %{
      "sid" => sid,
      "type" => "Allow",
      "rights" => rights,
      "isInherited" => Keyword.get(opts, :is_inherited, false),
      "inheritanceFlags" => Keyword.get(opts, :inheritance_flags, 0),
      "propagationFlags" => Keyword.get(opts, :propagation_flags, 0)
    }
  end

  defp deny_rule(sid, rights) do
    allow_rule(sid, rights) |> Map.put("type", "Deny")
  end
end
