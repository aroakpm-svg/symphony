defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{ProjectExecutionContext, ProjectProfiles, SubprocessEnvironment}

  test "project profiles are disabled when absent and available only as a complete valid set" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.project_profiles == nil

    assert {:ok, settings} =
             Schema.parse(%{"project_profiles" => valid_project_profiles_config()})

    assert {:ok, central} =
             ProjectProfiles.fetch(settings.project_profiles, "central-brain")

    assert central.repository == "aroakpm-svg/aroak-central-brain"
  end

  test "explicit null project profiles are malformed rather than treated as absent" do
    for config <- [%{"project_profiles" => nil}, %{project_profiles: nil}] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
      assert message =~ "project_profiles"
    end
  end

  test "invalid project profiles reject the whole workflow without exposing credential values" do
    invalid =
      update_in(
        valid_project_profiles_config(),
        ["profiles", Access.at(0)],
        &Map.put(&1, "credential_ref", "token=must-not-escape")
      )

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"project_profiles" => invalid})

    assert message =~ "project_profiles"
    refute message =~ "token=must-not-escape"
  end

  test "project profile key collisions are rejected before workflow normalization" do
    nested_collision =
      update_in(
        valid_project_profiles_config(),
        ["profiles", Access.at(0)],
        &Map.put(&1, :repository, "aroakpm-svg/attacker-controlled")
      )

    top_level_collision = %{
      "project_profiles" => valid_project_profiles_config(),
      project_profiles: valid_project_profiles_config()
    }

    for config <- [
          %{"project_profiles" => nested_collision},
          top_level_collision
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
      assert message =~ "project_profiles"
      refute message =~ "attacker-controlled"
    end
  end

  test "landing mode defaults to human and rejects automatic mode" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.landing.mode == :human

    assert {:ok, explicit} = Schema.parse(%{"landing" => %{"mode" => "human"}})
    assert explicit.landing.mode == :human

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"landing" => %{"mode" => "automatic"}})

    assert message =~ "landing.mode"
  end

  test "restart notifications require a safe absolute runtime-state root and complete local command config" do
    safe_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-state-#{System.unique_integer([:positive])}"
      )

    assert {:ok, defaults} = Schema.parse(%{})
    assert Path.type(defaults.observability.runtime_state_root) == :absolute
    assert defaults.observability.notification_command == nil
    assert defaults.observability.notification_receiver == nil
    assert defaults.observability.restart_limit > 0
    assert defaults.observability.notification_timeout_ms > 0

    assert {:ok, configured} =
             Schema.parse(%{
               observability: %{
                 runtime_state_root: safe_root,
                 notification_command: "pwsh -NoProfile -File notify.ps1",
                 notification_receiver: "on-call:platform",
                 restart_limit: 4,
                 notification_timeout_ms: 2_500
               }
             })

    assert configured.observability.runtime_state_root == safe_root
    assert configured.observability.notification_receiver == "on-call:platform"
    assert configured.observability.restart_limit == 4
    assert configured.observability.notification_timeout_ms == 2_500

    invalid_configs = [
      %{runtime_state_root: "relative/runtime-state"},
      %{runtime_state_root: Path.join(safe_root, "Production-runtime")},
      %{runtime_state_root: Path.join(safe_root, "token=canary-value")},
      %{runtime_state_root: safe_root, notification_command: "notify-local"},
      %{runtime_state_root: safe_root, notification_receiver: "on-call:platform"},
      %{
        runtime_state_root: safe_root,
        notification_command: " ",
        notification_receiver: "on-call:platform"
      },
      %{
        runtime_state_root: safe_root,
        notification_command: "notify-local",
        notification_receiver: " "
      },
      %{
        runtime_state_root: safe_root,
        notification_command: "notify-local Authorization: canary-value",
        notification_receiver: "on-call:platform"
      },
      %{
        runtime_state_root: safe_root,
        notification_command: "notify-local",
        notification_receiver: "token=canary-value"
      },
      %{
        runtime_state_root: safe_root,
        notification_command: "notify-local",
        notification_receiver: "on-call:platform",
        restart_limit: 0
      },
      %{
        runtime_state_root: safe_root,
        notification_command: "notify-local",
        notification_receiver: "on-call:platform",
        notification_timeout_ms: 0
      }
    ]

    for observability <- invalid_configs do
      message =
        case Schema.parse(%{observability: observability}) do
          {:error, {:invalid_workflow_config, message}} -> message
          {:ok, _settings} -> flunk("expected invalid observability configuration")
        end

      refute message =~ "canary-value"
      refute message =~ "notify-local"
      refute message =~ "on-call:platform"
    end

    separation_message =
      case Schema.parse(%{
             workspace: %{root: safe_root},
             observability: %{runtime_state_root: Path.join(safe_root, "runtime-state")}
           }) do
        {:error, {:invalid_workflow_config, message}} -> message
        {:ok, _settings} -> flunk("expected runtime-state/workspace separation error")
      end

    assert separation_message =~ "observability"
    refute separation_message =~ safe_root
  end

  test "runtime state and workspace roots reject overlap in both directions after relative and symlink resolution" do
    relative_workspace =
      "task6-relative-workspace-#{System.unique_integer([:positive])}"

    relative_runtime_root = Path.expand(Path.join(relative_workspace, "runtime-state"))

    relative_message =
      invalid_root_separation_message(%{
        workspace: %{root: relative_workspace},
        observability: %{runtime_state_root: relative_runtime_root}
      })

    assert relative_message =~ "observability.runtime_state_root"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "task6-config-separation-#{System.unique_integer([:positive])}"
      )

    runtime_root = Path.join(test_root, "runtime-state")
    workspace_inside_runtime = Path.join(runtime_root, "workspaces")
    workspace_alias = Path.join(test_root, "workspace-alias")

    File.mkdir_p!(workspace_inside_runtime)

    try do
      reverse_message =
        invalid_root_separation_message(%{
          workspace: %{root: workspace_inside_runtime},
          observability: %{runtime_state_root: runtime_root}
        })

      assert reverse_message =~ "observability.runtime_state_root"

      create_directory_link!(workspace_inside_runtime, workspace_alias)

      symlink_message =
        invalid_root_separation_message(%{
          workspace: %{root: workspace_alias},
          observability: %{runtime_state_root: runtime_root}
        })

      assert symlink_message =~ "observability.runtime_state_root"
    after
      _cleanup_link = File.rmdir(workspace_alias)
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 '#{shell_path(template_repo)}' ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) |> String.replace("\r\n", "\n") == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "project execution contexts isolate identical issue identifiers and cleanup only their target" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      central = project_context("central-brain", "ARO-286")
      management = project_context("project-management", "ARO-286")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, %{path: central_workspace, workspace_attestation: central_attestation}} =
               Workspace.prepare_for_issue("ARO-286", nil, central)

      assert {:ok, %{path: management_workspace}} =
               Workspace.prepare_for_issue("ARO-286", nil, management)

      assert {:ok, root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)
      assert central_workspace == Path.join([root, "central-brain", "ARO-286"])
      assert management_workspace == Path.join([root, "project-management", "ARO-286"])

      File.write!(Path.join([root, "central-brain", "namespace-marker.txt"]), "keep")
      File.write!(Path.join(root, "root-marker.txt"), "keep")

      assert :ok =
               Workspace.remove_issue_workspaces("ARO-286", nil, central, workspace_attestation: central_attestation)

      refute File.exists?(central_workspace)
      assert File.exists?(Path.join([root, "central-brain", "namespace-marker.txt"]))
      assert File.exists?(management_workspace)
      assert File.exists?(Path.join(root, "root-marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "project workspace rejects namespace symlink escapes and production-like roots" do
    unique_suffix =
      "#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-safety-#{unique_suffix}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      namespace_link = Path.join(workspace_root, "central-brain")
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      create_directory_link!(outside_root, namespace_link)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_namespace_outside_root, _canonical_namespace, ^canonical_workspace_root}} =
               Workspace.create_for_issue("ARO-286", nil, context)

      production_root = Path.join(test_root, "production-workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: production_root)

      assert {:error, {:workspace_production_root, ^production_root}} =
               Workspace.create_for_issue("ARO-286", nil, context)
    after
      File.rm_rf(test_root)
    end
  end

  test "context subprocess environment cannot mutate a rejected Production-like root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-production-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "Production-workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)
      refute File.exists?(workspace_root)
      refute File.exists?(paths.root)

      assert {:error, {:workspace_production_root, ^workspace_root}} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      refute File.exists?(workspace_root)
      refute File.exists?(paths.root)
    after
      File.rm_rf(test_root)
    end
  end

  test "context subprocess home rejects namespace aliases before touching sibling or outside targets" do
    for target_kind <- [:sibling, :outside] do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-namespace-#{target_kind}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      namespace_link = Path.join(workspace_root, "central-brain")

      target =
        case target_kind do
          :sibling -> Path.join(workspace_root, "project-management")
          :outside -> Path.join(test_root, "outside")
        end

      context = project_context("central-brain", "ARO-286")

      try do
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(target)
        File.write!(Path.join(target, "sentinel.txt"), "preserve")
        create_directory_link!(target, namespace_link)
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert {:ok, _environment} = SubprocessEnvironment.build(%{}, context)
        assert {:error, _reason} = Workspace.prepare_for_issue("ARO-286", nil, context)

        assert {:ok, ["sentinel.txt"]} = File.ls(target)
        refute File.exists?(Path.join(target, ".symphony-subprocess"))
      after
        remove_directory_link(namespace_link)
        File.rm_rf(test_root)
      end
    end
  end

  test "context subprocess home rejects aliases at every private descendant without following them" do
    for alias_kind <- [:root, :home, :gh, :codex] do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-#{alias_kind}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)
      outside_target = Path.join([test_root, "outside", Atom.to_string(alias_kind)])

      alias_path =
        case alias_kind do
          :root -> paths.root
          :home -> paths.home
          :gh -> paths.gh
          :codex -> paths.codex
        end

      try do
        File.mkdir_p!(Path.dirname(alias_path))
        File.mkdir_p!(outside_target)
        File.write!(Path.join(outside_target, "sentinel.txt"), "preserve")
        create_directory_link!(outside_target, alias_path)
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

        assert {:error, :subprocess_home_unavailable} =
                 Workspace.prepare_for_issue("ARO-286", nil, context,
                   env: environment,
                   subprocess_home_paths: paths
                 )

        assert {:ok, ["sentinel.txt"]} = File.ls(outside_target)
      after
        remove_directory_link(alias_path)
        File.rm_rf(test_root)
      end
    end
  end

  test "context subprocess home revalidates a component replaced at the creation seam" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-replacement-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    outside_target = Path.join(test_root, "outside")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      File.mkdir_p!(outside_target)
      File.write!(Path.join(outside_target, "sentinel.txt"), "preserve")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)
      File.rm_rf!(paths.root)

      replacement = fn path ->
        if path == paths.root do
          create_directory_link!(outside_target, path)
          send(self(), {:private_home_replaced, path})
        end

        :ok
      end

      assert {:error, :subprocess_home_unavailable} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths,
                 private_home_before_create: replacement
               )

      assert_received {:private_home_replaced, replaced_path}
      assert replaced_path == paths.root
      assert {:ok, ["sentinel.txt"]} = File.ls(outside_target)
      refute File.exists?(Path.join(outside_target, "ARO-286-r1"))
    after
      remove_directory_link(paths.root)
      File.rm_rf(test_root)
    end
  end

  test "validated context preparation creates canonical non-reparse owner-private subprocess homes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-valid-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)
      refute File.exists?(paths.root)

      assert {:ok, %{workspace_attestation: %{kind: :local}}} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      private_directories = [
        paths.root,
        paths.home,
        paths.gh,
        paths.xdg_config,
        paths.xdg_cache,
        paths.xdg_data,
        paths.codex
      ]

      Enum.each(private_directories, fn path ->
        assert {:ok, %File.Stat{type: :directory}} = File.lstat(path)
        assert {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)
        assert canonical_path == Path.expand(path)
        refute_windows_reparse_point(path)
      end)

      assert_owner_private_permissions(private_directories)
    after
      File.rm_rf(test_root)
    end
  end

  test "Windows reparse classification accepts only the non-reparse error code" do
    assert :ok =
             Workspace.classify_windows_reparse_query_for_test(
               "Error 4390: The file or directory is not a reparse point.\r\n",
               1
             )

    for {output, status} <- [
          {"Reparse Tag Value : 0xa000000c", 0},
          {"Error 5: Access is denied.", 1},
          {"Error 5: Access is denied for C:\\4390\\private-home.", 1},
          {"Access denied.\r\nDiagnostic code 4390", 1},
          {"Error 4390: Not a reparse point.\r\nError 5: Access is denied.", 1},
          {"Error 14390: unrelated", 1},
          {"", 1},
          {"Error 4390: The file or directory is not a reparse point.", 2}
        ] do
      assert {:error, :unsafe_private_home_path} =
               Workspace.classify_windows_reparse_query_for_test(output, status)
    end
  end

  test "context subprocess home rolls back every component created before a mid-creation failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-mid-create-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

      fail_before_create = fn path ->
        if path == paths.xdg_cache do
          assert_owner_private_permissions([
            paths.root,
            paths.home,
            paths.gh,
            paths.xdg_config
          ])

          send(self(), :prior_components_were_private)
          {:error, :injected_creation_failure}
        else
          :ok
        end
      end

      assert {:error, :subprocess_home_unavailable} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths,
                 private_home_before_create: fail_before_create
               )

      assert_received :prior_components_were_private
      Enum.each(private_directories(paths), &refute(File.exists?(&1)))
    after
      File.rm_rf(test_root)
    end
  end

  test "context subprocess home rolls back an injected permission failure without weak residue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-permission-failure-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

      assert {:error, :subprocess_home_unavailable} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths,
                 private_home_permission_failure: paths.gh
               )

      Enum.each(private_directories(paths), &refute(File.exists?(&1)))
    after
      File.rm_rf(test_root)
    end
  end

  test "pre-existing private components must already be owner-private and remain untouched on rejection" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-existing-permissions-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      File.mkdir_p!(paths.root)
      set_non_private_permissions!(paths.root)
      before_permissions = private_permissions_snapshot!(paths.root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

      assert {:error, :subprocess_home_unavailable} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      assert private_permissions_snapshot!(paths.root) == before_permissions
      refute File.exists?(paths.home)
    after
      File.rm_rf(test_root)
    end
  end

  test "Windows retained namespace capability blocks replacement after validation" do
    if match?({:win32, _name}, :os.type()) do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-retained-parent-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      namespace_path = Path.join(workspace_root, "central-brain")
      moved_namespace = Path.join(workspace_root, "central-brain-moved")
      outside_target = Path.join(test_root, "outside")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)

      try do
        File.mkdir_p!(outside_target)
        File.write!(Path.join(outside_target, "sentinel.txt"), "preserve")
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
        assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

        replacement = fn path ->
          if path == paths.root do
            rename_result = File.rename(namespace_path, moved_namespace)

            if rename_result == :ok do
              create_directory_link!(outside_target, namespace_path)
            end

            send(self(), {:namespace_rename_result, rename_result})
          end

          :ok
        end

        assert {:ok, _preparation} =
                 Workspace.prepare_for_issue("ARO-286", nil, context,
                   env: environment,
                   subprocess_home_paths: paths,
                   private_home_before_create: replacement
                 )

        assert_received {:namespace_rename_result, {:error, _reason}}
        refute File.exists?(moved_namespace)
        assert {:ok, ["sentinel.txt"]} = File.ls(outside_target)
        assert_owner_private_permissions(private_directories(paths))
      after
        remove_directory_link(namespace_path)

        if File.dir?(moved_namespace) and not File.exists?(namespace_path) do
          File.rename!(moved_namespace, namespace_path)
        end

        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end

  test "Windows post-create observer sees an atomically private pinned directory" do
    if match?({:win32, _name}, :os.type()) do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-atomic-acl-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)
      moved_root = paths.root <> "-moved"

      try do
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
        assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

        observer = fn path ->
          if path == paths.root do
            assert_owner_private_permissions([path])
            send(self(), {:post_create_rename, File.rename(path, moved_root)})
          end

          :ok
        end

        assert {:ok, %{private_home_capability: capability}} =
                 Workspace.prepare_for_issue("ARO-286", nil, context,
                   env: environment,
                   subprocess_home_paths: paths,
                   private_home_after_create: observer
                 )

        assert_received {:post_create_rename, {:error, _reason}}
        refute File.exists?(moved_root)
        assert :ok = Workspace.finalize_private_home_capability(capability)
      after
        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end

  test "preparation failure after private-home creation rolls back only this attempt's homes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-prepare-rollback-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "exit 23"
      )

      assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

      assert {:error, _reason} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      Enum.each(private_directories(paths), fn path ->
        refute File.exists?(path), "private-home residue remained at #{path}"
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "Windows commit failure is bounded, retires the capability, and rolls back new homes" do
    if match?({:win32, _name}, :os.type()) do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-commit-failure-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)

      try do
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
        assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

        assert {:ok, %{private_home_capability: capability}} =
                 Workspace.prepare_for_issue("ARO-286", nil, context,
                   env: environment,
                   subprocess_home_paths: paths,
                   private_home_commit_failure: true
                 )

        assert {:error, :subprocess_home_finalize_failed} =
                 Workspace.finalize_private_home_capability(capability)

        refute Workspace.private_home_capability_active_for_test?(capability)

        assert_eventually(fn ->
          Enum.all?(private_directories(paths), &(not File.exists?(&1)))
        end)
      after
        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end

  test "Windows rollback deletion failure is surfaced and never reported as success" do
    if match?({:win32, _name}, :os.type()) do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-rollback-failure-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)
      blocker = Path.join(paths.codex, "rollback-blocker")

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "exit 23"
        )

        assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

        post_create = fn path ->
          if path == paths.codex, do: File.write!(blocker, "retain")
          :ok
        end

        assert {:error, :subprocess_home_rollback_failed} =
                 Workspace.prepare_for_issue("ARO-286", nil, context,
                   env: environment,
                   subprocess_home_paths: paths,
                   private_home_after_create: post_create
                 )

        assert File.regular?(blocker)
      after
        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end

  test "Windows owner-process exit retires its helper and rolls back uncommitted homes" do
    if match?({:win32, _name}, :os.type()) do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aro286-private-home-owner-exit-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      paths = private_home_paths(workspace_root, context)
      parent = self()

      try do
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
        assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

        {owner, monitor} =
          spawn_monitor(fn ->
            result =
              Workspace.prepare_for_issue("ARO-286", nil, context,
                env: environment,
                subprocess_home_paths: paths
              )

            send(parent, {:owner_preparation, self(), result})
          end)

        assert_receive {:owner_preparation, ^owner, {:ok, _preparation}}, 15_000
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000

        assert_eventually(fn ->
          Enum.all?(private_directories(paths), &(not File.exists?(&1)))
        end)
      after
        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end

  test "private-home replacement after preparation is rejected before a credential-bearing hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-before-hook-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    hook_marker = Path.join(test_root, "hook.marker")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "printf unsafe > '#{shell_path(hook_marker)}'"
      )

      assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

      assert {:ok,
              %{
                path: workspace,
                workspace_attestation: workspace_attestation,
                private_home_capability: capability
              }} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      replace_or_weaken_private_home!(paths.codex)

      assert {:error, :subprocess_home_unavailable} =
               Workspace.run_before_run_hook(
                 workspace,
                 "ARO-286",
                 nil,
                 private_home_effect_opts(
                   environment,
                   paths,
                   context,
                   workspace_attestation,
                   capability
                 )
               )

      refute File.exists?(hook_marker)

      assert {:error, :subprocess_home_finalize_failed} =
               Workspace.finalize_private_home_capability(capability)
    after
      File.rm_rf(test_root)
    end
  end

  test "private-home replacement after preparation is rejected before a credential-bearing Git command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-before-git-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

      assert {:ok,
              %{
                path: workspace,
                workspace_attestation: workspace_attestation,
                private_home_capability: capability
              }} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      assert {_, 0} = System.cmd("git", ["-C", workspace, "init"])
      replace_or_weaken_private_home!(paths.codex)

      assert {:error, :subprocess_home_unavailable} =
               Workspace.run_git_command(
                 workspace,
                 ["rev-parse", "--is-inside-work-tree"],
                 nil,
                 private_home_effect_opts(
                   environment,
                   paths,
                   context,
                   workspace_attestation,
                   capability
                 )
               )

      assert {:error, :subprocess_home_finalize_failed} =
               Workspace.finalize_private_home_capability(capability)
    after
      File.rm_rf(test_root)
    end
  end

  test "private-home replacement after preparation is rejected before Codex AppServer opens a process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-private-home-before-codex-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)
    test_pid = self()

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, environment} = SubprocessEnvironment.build(%{"GH_TOKEN" => "approved"}, context)

      assert {:ok,
              %{
                path: workspace,
                workspace_attestation: workspace_attestation,
                private_home_capability: capability
              }} =
               Workspace.prepare_for_issue("ARO-286", nil, context,
                 env: environment,
                 subprocess_home_paths: paths
               )

      replace_or_weaken_private_home!(paths.codex)

      port_opener = fn _spawn_target, _port_opts ->
        send(test_pid, :unsafe_codex_process_opened)
        raise "Codex process must not open"
      end

      assert {:error, :subprocess_home_unavailable} =
               AppServer.start_session(
                 workspace,
                 Keyword.put(
                   private_home_effect_opts(
                     environment,
                     paths,
                     context,
                     workspace_attestation,
                     capability
                   ),
                   :port_opener,
                   port_opener
                 )
               )

      refute_received :unsafe_codex_process_opened

      assert {:error, :subprocess_home_finalize_failed} =
               Workspace.finalize_private_home_capability(capability)
    after
      File.rm_rf(test_root)
    end
  end

  test "POSIX private permission validation requires mode 0700 and effective ownership" do
    effective_uid = 1_001

    assert :ok =
             Workspace.validate_posix_private_permissions_for_test(
               %File.Stat{type: :directory, mode: 0o700, uid: effective_uid},
               effective_uid
             )

    for stat <- [
          %File.Stat{type: :directory, mode: 0o755, uid: effective_uid},
          %File.Stat{type: :directory, mode: 0o700, uid: effective_uid + 1},
          %File.Stat{type: :regular, mode: 0o700, uid: effective_uid}
        ] do
      assert {:error, :private_home_permissions_failed} =
               Workspace.validate_posix_private_permissions_for_test(stat, effective_uid)
    end
  end

  test "POSIX rollback tracking adds only directories created by this mkdir call" do
    path = "/private/issue-home"
    existing = [{"/private/root", %{type: :directory, inode: 10, uid: 1_001}}]
    identity = %{type: :directory, major_device: 1, minor_device: 2, inode: 11, uid: 1_001}
    test_pid = self()

    for mkdir_result <- [{:error, :eexist}, {:error, :eacces}] do
      mkdir = fn ^path -> mkdir_result end

      identity_reader = fn _unexpected ->
        send(test_pid, :identity_read_for_uncreated_directory)
        {:ok, identity}
      end

      assert {:error, :private_home_create_failed, ^existing} =
               Workspace.posix_mkdir_and_track_for_test(
                 path,
                 existing,
                 mkdir,
                 identity_reader
               )

      refute_received :identity_read_for_uncreated_directory
    end

    assert {:ok, ^identity, [{^path, ^identity} | ^existing]} =
             Workspace.posix_mkdir_and_track_for_test(
               path,
               existing,
               fn ^path -> :ok end,
               fn ^path -> {:ok, identity} end
             )

    assert {:error, :private_home_rollback_failed, ^existing} =
             Workspace.posix_mkdir_and_track_for_test(
               path,
               existing,
               fn ^path -> :ok end,
               fn ^path -> {:error, :identity_unavailable} end
             )

    assert {:error, :private_home_rollback_failed, ^existing} =
             Workspace.posix_mkdir_and_track_for_test(
               path,
               existing,
               fn ^path -> :ok end,
               fn ^path -> raise "identity read failed" end
             )
  end

  test "POSIX rollback revalidates owner identity, removes newest-first, and reports every failure" do
    parent = "/private/root"
    child = "/private/root/issue-home"

    parent_identity =
      %{type: :directory, major_device: 1, minor_device: 2, inode: 10, uid: 1_001}

    child_identity =
      %{type: :directory, major_device: 1, minor_device: 2, inode: 11, uid: 1_001}

    created = [{child, child_identity}, {parent, parent_identity}]
    test_pid = self()

    identity_reader = fn
      ^child -> {:ok, child_identity}
      ^parent -> {:ok, parent_identity}
    end

    assert :ok =
             Workspace.rollback_posix_private_home_for_test(
               created,
               identity_reader,
               fn path ->
                 send(test_pid, {:removed, path})
                 :ok
               end
             )

    assert_received {:removed, ^child}
    assert_received {:removed, ^parent}

    changed_reader = fn
      ^child -> {:ok, %{child_identity | inode: 99}}
      ^parent -> {:ok, parent_identity}
    end

    assert {:error, :private_home_rollback_failed} =
             Workspace.rollback_posix_private_home_for_test(
               created,
               changed_reader,
               fn path ->
                 send(test_pid, {:unsafe_remove, path})
                 :ok
               end
             )

    refute_received {:unsafe_remove, ^child}
    assert_received {:unsafe_remove, ^parent}

    assert {:error, :private_home_rollback_failed} =
             Workspace.rollback_posix_private_home_for_test(
               created,
               identity_reader,
               fn
                 ^child -> {:error, :eacces}
                 ^parent -> :ok
               end
             )
  end

  test "context cleanup without an attestation preserves the workspace and creates no private home or hook effect" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-cleanup-no-attestation-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join([workspace_root, "central-brain", "ARO-286"])
    hook_marker = Path.join(test_root, "cleanup-hook.txt")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "preserve.txt"), "preserve")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo unsafe > '#{shell_path(hook_marker)}'"
      )

      assert :ok = Workspace.remove_issue_workspaces("ARO-286", nil, context)
      assert File.read!(Path.join(workspace, "preserve.txt")) == "preserve"
      refute File.exists?(paths.root)
      refute File.exists?(hook_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "attested context cleanup never creates a missing private home for a credential-bearing hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-cleanup-missing-home-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    hook_marker = Path.join(test_root, "cleanup-hook.txt")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo unsafe > '#{shell_path(hook_marker)}'"
      )

      assert {:ok, %{path: workspace, workspace_attestation: attestation}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      refute File.exists?(paths.root)

      assert :ok =
               Workspace.remove_issue_workspaces("ARO-286", nil, context, workspace_attestation: attestation)

      assert File.dir?(workspace)
      refute File.exists?(paths.root)
      refute File.exists?(hook_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "attested context cleanup without a hook removes the workspace without creating a private home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aro286-cleanup-no-hook-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    context = project_context("central-brain", "ARO-286")
    paths = private_home_paths(workspace_root, context)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, %{path: workspace, workspace_attestation: attestation}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      refute File.exists?(paths.root)

      assert :ok =
               Workspace.remove_issue_workspaces("ARO-286", nil, context, workspace_attestation: attestation)

      refute File.exists?(workspace)
      refute File.exists?(paths.root)
    after
      File.rm_rf(test_root)
    end
  end

  test "project workspace rejects an in-root namespace alias without touching its target" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-alias-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      management_workspace = Path.join([workspace_root, "project-management", "ARO-286"])
      central_namespace = Path.join(workspace_root, "central-brain")
      hook_marker = Path.join(management_workspace, "before-remove-marker.txt")
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(management_workspace)
      File.write!(Path.join(management_workspace, "marker.txt"), "management")
      create_directory_link!(Path.join(workspace_root, "project-management"), central_namespace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo unsafe > before-remove-marker.txt"
      )

      assert {:error, {:workspace_namespace_identity_mismatch, _actual, _expected}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      assert :ok = Workspace.remove_issue_workspaces("ARO-286", nil, context)
      assert File.read!(Path.join(management_workspace, "marker.txt")) == "management"
      refute File.exists?(hook_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "project workspace rejects a same-namespace issue leaf alias without touching its sibling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-leaf-alias-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      sibling_workspace = Path.join([workspace_root, "central-brain", "ARO-287"])
      expected_workspace = Path.join([workspace_root, "central-brain", "ARO-286"])
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(sibling_workspace)
      File.write!(Path.join(sibling_workspace, "marker.txt"), "sibling")
      create_directory_link!(sibling_workspace, expected_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo unsafe > before-remove-marker.txt"
      )

      assert {:error, {:workspace_issue_identity_mismatch, _actual, _expected}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      assert :ok = Workspace.remove_issue_workspaces("ARO-286", nil, context)
      assert File.read!(Path.join(sibling_workspace, "marker.txt")) == "sibling"
      refute File.exists?(Path.join(sibling_workspace, "before-remove-marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "project workspace revalidates a replaced issue leaf immediately before a local hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-replaced-leaf-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "echo unsafe > before-run-marker.txt"
      )

      assert {:ok, %{path: expected_workspace, workspace_attestation: attestation}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      displaced_workspace = expected_workspace <> "-original"
      File.rename!(expected_workspace, displaced_workspace)
      File.mkdir_p!(expected_workspace)

      assert {:error, {:workspace_issue_identity_changed, actual, ^attestation}} =
               Workspace.run_before_run_hook(expected_workspace, "ARO-286", nil,
                 execution_context: context,
                 workspace_attestation: attestation
               )

      refute actual.identity == attestation.identity

      refute File.exists?(Path.join(expected_workspace, "before-run-marker.txt"))
      refute File.exists?(Path.join(displaced_workspace, "before-run-marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "project workspace identity survives normal content mutation across local effect boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stable-identity-#{System.unique_integer([:positive])}"
      )

    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    System.delete_env("SOURCE_REPO_URL")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      cleanup_marker = Path.join(test_root, "before-remove-marker.txt")
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "stable identity\n")
      assert {_, 0} = System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      assert {_, 0} = System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      assert {_, 0} = System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      assert {_, 0} = System.cmd("git", ["-C", template_repo, "add", "README.md"])
      assert {_, 0} = System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])
      context = %{context | repository: shell_path(template_repo)}

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 '#{shell_path(template_repo)}' .",
        hook_before_run: "echo hook > before-run-marker.txt",
        hook_before_remove: "echo cleanup > '#{shell_path(cleanup_marker)}'"
      )

      assert {:ok, environment} = SubprocessEnvironment.build(%{}, context)

      preparation_opts = [
        env: environment,
        subprocess_home_paths: SubprocessEnvironment.private_home_paths(context)
      ]

      assert {:ok,
              %{
                path: workspace,
                workspace_attestation: attestation,
                private_home_capability: capability
              }} =
               Workspace.prepare_for_issue("ARO-286", nil, context, preparation_opts)

      transient_directory = Path.join(workspace, "codex-created")
      transient_file = Path.join(workspace, "hook-created.txt")
      File.mkdir_p!(transient_directory)
      File.write!(transient_file, "temporary")
      File.rm_rf!(transient_directory)
      File.rm!(transient_file)

      effect_opts =
        preparation_opts ++
          [
            execution_context: context,
            workspace_attestation: attestation,
            private_home_capability: capability
          ]

      assert :ok = Workspace.preflight(workspace, "ARO-286", nil, effect_opts)
      assert :ok = Workspace.run_before_run_hook(workspace, "ARO-286", nil, effect_opts)
      assert File.read!(Path.join(workspace, "before-run-marker.txt")) == "hook\n"

      parent = self()

      port_opener = fn _spawn_target, _port_opts ->
        send(parent, :app_server_workspace_validated)
        raise "app server process boundary reached"
      end

      assert_raise RuntimeError, "app server process boundary reached", fn ->
        AppServer.start_session(workspace, effect_opts ++ [port_opener: port_opener])
      end

      assert_receive :app_server_workspace_validated

      assert :ok = Workspace.finalize_private_home_capability(capability)

      assert :ok =
               Workspace.remove_issue_workspaces("ARO-286", nil, context, workspace_attestation: attestation)

      assert File.read!(cleanup_marker) == "cleanup\n"
      refute File.exists?(workspace)
    after
      restore_env("SOURCE_REPO_URL", previous_source_repo_url)
      File.rm_rf(test_root)
    end
  end

  test "POSIX workspace identity rejects unavailable or invalid directory coordinates" do
    valid_stat = %File.Stat{
      type: :directory,
      major_device: 3,
      minor_device: 7,
      inode: 11
    }

    assert {:ok, %{type: :directory, major_device: 3, minor_device: 7, inode: 11}} =
             Workspace.posix_file_identity_for_test(valid_stat)

    private_stat = %{valid_stat | uid: 1_001}

    assert {:ok,
            %{
              type: :directory,
              major_device: 3,
              minor_device: 7,
              inode: 11,
              uid: 1_001
            }} = Workspace.posix_private_file_identity_for_test(private_stat)

    for invalid_uid <- [:undefined, nil, "1001", -1] do
      assert {:error, :invalid_posix_private_file_identity} =
               Workspace.posix_private_file_identity_for_test(%{
                 private_stat
                 | uid: invalid_uid
               })
    end

    for {field, invalid_value} <- [
          {:major_device, :undefined},
          {:minor_device, :undefined},
          {:inode, :undefined},
          {:major_device, "3"},
          {:minor_device, 7.0},
          {:inode, nil},
          {:major_device, -1},
          {:minor_device, -1},
          {:inode, -1},
          {:type, :regular}
        ] do
      invalid_stat = Map.replace!(valid_stat, field, invalid_value)

      assert {:error, :invalid_posix_file_identity} =
               Workspace.posix_file_identity_for_test(invalid_stat)
    end
  end

  test "Windows file identity parser accepts exactly one standalone native ID token" do
    file_id = "0x0123456789abcdefABCDEF0123456789"
    normalized_file_id = "0x0123456789abcdefabcdef0123456789"

    assert {:ok, ^normalized_file_id} =
             Workspace.parse_windows_file_id_for_test("File ID is #{file_id}\r\n")

    for invalid_output <- [
          "",
          "File ID is unavailable",
          "File ID is 0x0123",
          "prefix#{file_id}",
          "#{file_id}suffix",
          "File ID is (#{file_id})",
          "File ID is #{file_id}0",
          "File IDs are #{file_id} #{file_id}"
        ] do
      assert {:error, :invalid_windows_file_id_output} =
               Workspace.parse_windows_file_id_for_test(invalid_output)
    end
  end

  test "project cleanup preserves a replacement issue leaf after readiness" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-replaced-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo unsafe > before-remove-marker.txt"
      )

      assert {:ok, %{path: expected_workspace, workspace_attestation: attestation}} =
               Workspace.prepare_for_issue("ARO-286", nil, context)

      displaced_workspace = expected_workspace <> "-original"
      File.rename!(expected_workspace, displaced_workspace)
      File.mkdir_p!(expected_workspace)
      File.write!(Path.join(expected_workspace, "replacement.txt"), "preserve")

      assert :ok =
               Workspace.remove_issue_workspaces("ARO-286", nil, context, workspace_attestation: attestation)

      assert File.read!(Path.join(expected_workspace, "replacement.txt")) == "preserve"
      assert File.dir?(displaced_workspace)
      refute File.exists?(Path.join(expected_workspace, "before-remove-marker.txt"))
      refute File.exists?(Path.join(displaced_workspace, "before-remove-marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "remote project hook rejects a replaced or linked issue leaf before mutation" do
    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    context = project_context("central-brain", "ARO-286")
    parent = self()

    Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, args, _opts ->
      command = List.last(args)
      send(parent, {:remote_hook_command, command})

      if remote_check_precedes_mutation?(
           command,
           "if [ -L \"$workspace\" ]; then exit 1; fi",
           ["echo unsafe"]
         ) and command =~ "workspace_physical" and command =~ "expected_workspace" do
        if command =~ "current_workspace_identity" and command =~ "expected_workspace_identity" do
          {"unsafe issue leaf", 1}
        else
          send(parent, :unsafe_remote_hook_ran)
          {"", 0}
        end
      else
        send(parent, :unsafe_remote_hook_ran)
        {"", 0}
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/tmp/symphony-workspaces",
      worker_ssh_hosts: ["worker-01"],
      hook_before_run: "echo unsafe"
    )

    workspace = "/tmp/symphony-workspaces/central-brain/ARO-286"

    assert {:error, {:workspace_hook_failed, "before_run", 1, "unsafe issue leaf"}} =
             Workspace.run_before_run_hook(workspace, "ARO-286", "worker-01",
               execution_context: context,
               workspace_attestation: %{kind: :remote, identity: "1:286"}
             )

    assert_receive {:remote_hook_command, _command}
    refute_receive :unsafe_remote_hook_ran
  end

  test "remote namespace alias fails closed before the before_remove hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-context-alias-#{System.unique_integer([:positive])}"
      )

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      management_workspace = Path.join([workspace_root, "project-management", "ARO-286"])
      central_namespace = Path.join(workspace_root, "central-brain")
      hook_marker = Path.join(management_workspace, "before-remove-marker.txt")
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(management_workspace)
      create_directory_link!(Path.join(workspace_root, "project-management"), central_namespace)

      Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, args, _opts ->
        command = List.last(args)

        cond do
          command =~ "rm -rf \"$workspace\"" and
              remote_check_precedes_mutation?(command, "if [ \"$namespace_physical\" != \"$expected_namespace\" ]; then exit 1; fi", [
                "echo unsafe > before-remove-marker.txt"
              ]) ->
            {"unsafe namespace", 1}

          command =~ "echo unsafe > before-remove-marker.txt" ->
            File.write!(hook_marker, "unsafe")
            {"", 0}

          command =~ "rm -rf \"$workspace\"" ->
            File.write!(hook_marker, "unsafe")
            {"unsafe namespace", 1}

          true ->
            {"", 0}
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_before_remove: "echo unsafe > before-remove-marker.txt"
      )

      assert :ok = Workspace.remove_issue_workspaces("ARO-286", "worker-01", context)
      refute File.exists?(hook_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "context issue identifier mismatches fail before local or remote workspace handling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-context-identifier-#{System.unique_integer([:positive])}"
      )

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      context = project_context("central-brain", "ARO-286")
      test_pid = self()

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, :workspace_context_identity_mismatch} =
               Workspace.prepare_for_issue("ARO-287", nil, context)

      refute File.exists?(Path.join([workspace_root, "central-brain", "ARO-286.symphony-readiness-v1.json"]))

      Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, _args, _opts ->
        send(test_pid, :remote_workspace_called)
        {"", 0}
      end)

      assert {:error, :workspace_context_identity_mismatch} =
               Workspace.prepare_for_issue("ARO-287", "worker-01", context)

      refute_received :remote_workspace_called

      assert :ok = Workspace.remove_issue_workspaces("ARO-287", "worker-01", context)
      refute_received :remote_workspace_called
    after
      File.rm_rf(test_root)
    end
  end

  test "remote context workspace validates physical namespace identity before mutation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-context-order-#{System.unique_integer([:positive])}"
      )

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    try do
      context = project_context("central-brain", "ARO-286")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/central-brain/ARO-286"

      Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, args, _opts ->
        command = List.last(args)

        cond do
          command =~ "__SYMPHONY_WORKSPACE__" and
              remote_check_precedes_mutation?(command, "namespace_physical=", ["rm -rf \"$workspace\"", "mkdir -p \"$workspace\""]) ->
            {"__SYMPHONY_WORKSPACE__\t1\t#{workspace_path}\t1:286\n", 0}

          command =~ "__SYMPHONY_WORKSPACE__" ->
            {"remote namespace validation was late", 17}

          command =~ "rm -rf \"$workspace\"" and
            remote_check_precedes_mutation?(command, "if [ \"$parent_physical\" != \"$namespace_physical\" ]; then exit 1; fi", [
              "echo remote-before-remove",
              "rm -rf \"$workspace\""
            ]) and
            remote_check_precedes_mutation?(command, "echo remote-before-remove", ["rm -rf \"$workspace\""]) and
              length(String.split(command, "echo remote-before-remove")) == 2 ->
            {"", 0}

          command =~ "rm -rf \"$workspace\"" ->
            {"remote cleanup hook was not validated before removing the workspace", 17}

          true ->
            {"", 0}
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_before_remove: "echo remote-before-remove"
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("ARO-286", "worker-01", context)
      assert :ok = Workspace.remove_issue_workspaces("ARO-286", "worker-01", context)
    after
      File.rm_rf(test_root)
    end
  end

  test "remote project workspace uses the same context namespace and cleanup target" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-context-#{System.unique_integer([:positive])}"
      )

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/central-brain/ARO-286"
      context = project_context("central-brain", "ARO-286")

      File.mkdir_p!(test_root)

      Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, args, _opts ->
        command = Enum.join(args, " ")
        File.write!(trace_file, command <> "\n", [:append])

        output =
          if command =~ "__SYMPHONY_WORKSPACE__" do
            "__SYMPHONY_WORKSPACE__\t1\t#{workspace_path}\t1:286\n"
          else
            ""
          end

        {output, 0}
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("ARO-286", "worker-01", context)
      assert :ok = Workspace.remove_issue_workspaces("ARO-286", "worker-01", context)

      trace = File.read!(trace_file)
      assert trace =~ "~/.symphony-remote-workspaces/central-brain/ARO-286"
      refute trace =~ "rm -rf '~/.symphony-remote-workspaces'"
      refute trace =~ "rm -rf '~/.symphony-remote-workspaces/central-brain'"
      refute trace =~ "\nnil\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      create_directory_link!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      create_directory_link!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear issue routing requires every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], assigned_to_worker: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | assigned_to_worker: false}, ["symphony"])
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == workspace_root
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "env file loader reads every assignment before falling back to raw token format" do
    workflow_path = Workflow.workflow_file_path()
    env_path = Path.join(Path.dirname(workflow_path), ".env.local")

    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    previous_codex_default_model = System.get_env("CODEX_DEFAULT_MODEL")
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("SOURCE_REPO_URL", previous_source_repo_url)
      restore_env("CODEX_DEFAULT_MODEL", previous_codex_default_model)
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("SOURCE_REPO_URL")
    System.delete_env("CODEX_DEFAULT_MODEL")
    System.delete_env("LINEAR_ASSIGNEE")

    File.write!(env_path, """
    LINEAR_API_KEY=linear-token
    SOURCE_REPO_URL=https://github.com/aroakpm-svg/aroak-central-brain.git
    CODEX_DEFAULT_MODEL=gpt-5.5
    export LINEAR_ASSIGNEE=dmtriumphs@example.com
    """)

    assert :ok = SymphonyElixir.EnvFile.load_local(workflow_path)

    assert System.get_env("LINEAR_API_KEY") == "linear-token"
    assert System.get_env("SOURCE_REPO_URL") == "https://github.com/aroakpm-svg/aroak-central-brain.git"
    assert System.get_env("CODEX_DEFAULT_MODEL") == "gpt-5.5"
    assert System.get_env("LINEAR_ASSIGNEE") == "dmtriumphs@example.com"
  end

  test "env file loader treats existing env assignments as env-style files" do
    workflow_path = Workflow.workflow_file_path()
    env_path = Path.join(Path.dirname(workflow_path), ".env.local")

    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("SOURCE_REPO_URL", previous_source_repo_url)
    end)

    System.put_env("LINEAR_API_KEY", "existing-token")
    System.delete_env("SOURCE_REPO_URL")

    File.write!(env_path, """
    LINEAR_API_KEY=file-token-that-should-not-overwrite
    SOURCE_REPO_URL=https://github.com/aroakpm-svg/aroak-central-brain.git
    """)

    assert :ok = SymphonyElixir.EnvFile.load_local(workflow_path)

    assert System.get_env("LINEAR_API_KEY") == "existing-token"
    assert System.get_env("SOURCE_REPO_URL") == "https://github.com/aroakpm-svg/aroak-central-brain.git"
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    if elem(:os.type(), 0) == :win32 do
      assert {:ok, ^expanded_path} = SymphonyElixir.PathSafety.canonicalize(path)
    else
      assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
               SymphonyElixir.PathSafety.canonicalize(path)
    end
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_runner = Application.get_env(:symphony_elixir, :ssh_command_runner)

    on_exit(fn ->
      if previous_runner do
        Application.put_env(:symphony_elixir, :ssh_command_runner, previous_runner)
      else
        Application.delete_env(:symphony_elixir, :ssh_command_runner)
      end
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)

      Application.put_env(:symphony_elixir, :ssh_command_runner, fn _executable, args, _opts ->
        command = Enum.join(args, " ")
        File.write!(trace_file, "ARGV:" <> command <> "\n", [:append])

        output =
          if command =~ "__SYMPHONY_WORKSPACE__" do
            "__SYMPHONY_WORKSPACE__\t1\t#{workspace_path}\n"
          else
            ""
          end

        {output, 0}
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 sh -c"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp valid_project_profiles_config do
    %{
      "version" => 1,
      "profiles" => [
        %{
          "key" => "central-brain",
          "linear_project_id" => "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec",
          "repository" => "aroakpm-svg/aroak-central-brain",
          "canonical_branch" => "main",
          "workspace_namespace" => "central-brain",
          "credential_ref" => "github-central-brain",
          "environment" => "local_non_production"
        },
        %{
          "key" => "project-management",
          "linear_project_id" => "708053e0-f42c-4e93-bec4-7abbb37e74af",
          "repository" => "aroakpm-svg/aroak-project-management",
          "canonical_branch" => "main",
          "workspace_namespace" => "project-management",
          "credential_ref" => "github-project-management",
          "environment" => "local_non_production"
        }
      ]
    }
  end

  defp project_context(namespace, issue_identifier, overrides \\ []) do
    attrs = %{
      issue_id: "issue-#{issue_identifier}",
      issue_identifier: issue_identifier,
      profile_key: namespace,
      linear_project_id: "d0acfb71-f68c-4e93-bec4-7abbb37e74af",
      repository: "aroakpm-svg/#{namespace}",
      canonical_branch: "main",
      workspace_namespace: namespace,
      credential_ref: "github-#{namespace}",
      environment: "local_non_production",
      routing_revision: 1
    }

    struct!(ProjectExecutionContext, Map.merge(attrs, Map.new(overrides)))
  end

  defp private_home_paths(workspace_root, context) do
    root =
      Path.join([
        Path.expand(workspace_root),
        context.workspace_namespace,
        ".symphony-subprocess"
      ])

    home = Path.join(root, "#{context.issue_identifier}-r#{context.routing_revision}")

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

  defp private_directories(paths) do
    [
      paths.root,
      paths.home,
      paths.gh,
      paths.xdg_config,
      paths.xdg_cache,
      paths.xdg_data,
      paths.codex
    ]
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, 0) do
    assert predicate.()
  end

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp private_home_effect_opts(
         environment,
         paths,
         context,
         workspace_attestation,
         capability
       ) do
    [
      env: environment,
      subprocess_home_paths: paths,
      execution_context: context,
      workspace_attestation: workspace_attestation,
      private_home_capability: capability
    ]
  end

  defp replace_or_weaken_private_home!(path) do
    moved_path = path <> "-moved"

    case File.rename(path, moved_path) do
      :ok ->
        :ok

      {:error, _reason} ->
        set_non_private_permissions!(path)
    end
  end

  defp set_non_private_permissions!(path) do
    case :os.type() do
      {:unix, _name} ->
        File.chmod!(path, 0o755)

      {:win32, _name} ->
        script = """
        $ErrorActionPreference = 'Stop'
        $path = $env:SYMPHONY_PRIVATE_HOME_PATH
        $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $users = [Security.Principal.SecurityIdentifier]::new(
          [Security.Principal.WellKnownSidType]::BuiltinUsersSid,
          $null
        )
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($current)
        $acl.SetAccessRuleProtection($true, $false)
        $ownerRule = [Security.AccessControl.FileSystemAccessRule]::new(
          $current,
          [Security.AccessControl.FileSystemRights]::FullControl,
          [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
          [Security.AccessControl.PropagationFlags]::None,
          [Security.AccessControl.AccessControlType]::Allow
        )
        $usersRule = [Security.AccessControl.FileSystemAccessRule]::new(
          $users,
          [Security.AccessControl.FileSystemRights]::ReadAndExecute,
          [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
          [Security.AccessControl.PropagationFlags]::None,
          [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($ownerRule)
        $acl.AddAccessRule($usersRule)
        [IO.DirectoryInfo]::new($path).SetAccessControl($acl)
        """

        assert {"", 0} =
                 System.cmd(
                   windows_powershell!(),
                   ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                   env: [{"SYMPHONY_PRIVATE_HOME_PATH", path}]
                 )
    end
  end

  defp private_permissions_snapshot!(path) do
    case :os.type() do
      {:unix, _name} ->
        stat = File.stat!(path)
        %{mode: Bitwise.band(stat.mode, 0o777), uid: stat.uid}

      {:win32, _name} ->
        script = """
        $ErrorActionPreference = 'Stop'
        $acl = [IO.DirectoryInfo]::new($env:SYMPHONY_PRIVATE_HOME_PATH).GetAccessControl()
        [Console]::Out.Write($acl.GetSecurityDescriptorSddlForm(
          [Security.AccessControl.AccessControlSections]::All
        ))
        """

        {snapshot, 0} =
          System.cmd(
            windows_powershell!(),
            ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            stderr_to_stdout: true,
            env: [{"SYMPHONY_PRIVATE_HOME_PATH", path}]
          )

        snapshot
    end
  end

  defp windows_powershell! do
    Path.join([
      System.fetch_env!("SystemRoot"),
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe"
    ])
  end

  defp remove_directory_link(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        _removed = File.rm(path)
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        _removed = File.rmdir(path)
        :ok

      _missing_or_other ->
        :ok
    end
  end

  defp refute_windows_reparse_point(path) do
    if match?({:win32, _}, :os.type()) do
      executable = Path.join([System.fetch_env!("SystemRoot"), "System32", "fsutil.exe"])
      {_output, status} = System.cmd(executable, ["reparsepoint", "query", path], stderr_to_stdout: true)
      refute status == 0, "expected #{path} not to be a Windows reparse point"
    end
  end

  defp assert_owner_private_permissions(paths) do
    case :os.type() do
      {:unix, _name} ->
        Enum.each(paths, fn path ->
          assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
          assert Bitwise.band(mode, 0o777) == 0o700
        end)

      {:win32, _name} ->
        script = """
        $ErrorActionPreference = 'Stop'
        $paths = $env:SYMPHONY_PRIVATE_HOME_PATHS | ConvertFrom-Json
        if ($paths.Count -lt 1) { exit 19 }
        $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($path in $paths) {
          $directory = [IO.DirectoryInfo]::new($path)
          $acl = $directory.GetAccessControl()
          if (-not $acl.AreAccessRulesProtected) { exit 20 }
          $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
          if ($rules.Count -lt 1) { exit 21 }
          foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -ne $current) { exit 22 }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { exit 23 }
          }
          $full = [int][Security.AccessControl.FileSystemRights]::FullControl
          $currentFull = @($rules | Where-Object {
            $_.IdentityReference.Value -eq $current -and
            (([int]$_.FileSystemRights -band $full) -eq $full)
          })
          if ($currentFull.Count -lt 1) { exit 24 }
        }
        """

        executable =
          Path.join([
            System.fetch_env!("SystemRoot"),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe"
          ])

        {output, status} =
          System.cmd(
            executable,
            ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            stderr_to_stdout: true,
            env: [{"SYMPHONY_PRIVATE_HOME_PATHS", Jason.encode!(paths)}]
          )

        assert status == 0, "expected owner-private Windows ACLs, status=#{status}: #{output}"
    end
  end

  defp invalid_root_separation_message(config) do
    case Schema.parse(config) do
      {:error, {:invalid_workflow_config, message}} -> message
      {:ok, _settings} -> flunk("expected runtime-state/workspace separation error")
    end
  end

  defp remote_check_precedes_mutation?(command, check, mutations) do
    case :binary.match(command, check) do
      :nomatch ->
        false

      {check_index, _} ->
        mutations
        |> Enum.map(fn mutation -> :binary.match(command, mutation) end)
        |> then(fn matches ->
          Enum.all?(matches, &(&1 != :nomatch)) and
            Enum.all?(matches, fn {mutation_index, _} -> check_index < mutation_index end)
        end)
    end
  end
end
