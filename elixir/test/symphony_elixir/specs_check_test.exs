defmodule SymphonyElixir.SpecsCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SpecsCheck

  import SymphonyElixir.TestSupport, only: [create_directory_link!: 2]

  test "reports missing @spec for public functions" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "accepts adjacent @spec on public function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "allows defp without @spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def public do
        helper(:ok)
      end

      defp helper(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.public/0"]
  end

  test "exempts callback implementations marked with @impl" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", """
    defmodule Worker do
      @behaviour GenServer

      @impl true
      def init(state), do: {:ok, state}
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "honors explicit exemptions list" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def legacy(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir], exemptions: ["Sample.legacy/1"])

    assert findings == []
  end

  test "does not follow directory links while collecting source files" do
    dir = create_tmp_dir()
    nested_dir = Path.join(dir, "nested")
    File.mkdir_p!(nested_dir)

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg), do: arg
    end
    """)

    create_directory_link!(dir, Path.join(nested_dir, "back"))

    task = Task.async(fn -> SpecsCheck.missing_public_specs([dir]) end)
    result = Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)

    assert {:ok, findings} = result
    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "includes source-file symlinks without traversing linked directories" do
    dir = create_tmp_dir()
    target_dir = Path.join(dir, "target")
    File.mkdir_p!(target_dir)

    target =
      write_module!(target_dir, "linked_source", """
      defmodule LinkedSource do
        def missing(arg), do: arg
      end
      """)

    linked_source = Path.join(dir, "linked_source.ex")

    case File.ln_s(target, linked_source) do
      :ok ->
        findings = SpecsCheck.missing_public_specs([linked_source])
        assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["LinkedSource.missing/1"]

      {:error, :eperm} ->
        :ok
    end
  end

  test "the checked-in runtime docs describe fail-closed finding disposition" do
    spec = File.read!(Path.expand("../../../SPEC.md", __DIR__))
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert spec =~ "FindingKey"
    assert spec =~ "evaluated_head_sha"
    assert readme =~ "fix_in_current_pr"
    assert readme =~ "does not authorize merge"
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "specs-check-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write_module!(dir, rel_path, source) do
    path = Path.join(dir, rel_path)
    File.write!(path, source)
    path
  end
end
