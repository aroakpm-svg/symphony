defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check

  import ExUnit.CaptureIO

  @template """
  #### Context

  <!-- Why is this change needed? -->

  #### TL;DR

  *<!-- A short summary -->*

  #### Summary

  - <!-- Summary bullet -->

  #### Alternatives

  - <!-- Alternative bullet -->

  #### Test Plan

  - [ ] <!-- Test checkbox -->

  #### Scope Contract

  <!-- Define the exact work boundary this PR must preserve. -->

  ##### Work Item

  <!-- One concrete change this PR delivers. -->

  ##### Invariants

  - <!-- Behavior, safety, or compatibility rule that must remain true. -->

  ##### Acceptance Criteria

  - <!-- AC-1: Observable completion condition. -->

  ##### Non-Goals

  - <!-- Explicitly excluded work. -->

  ##### Dependencies

  <!-- Upstream work or external prerequisite, or None. -->

  ##### Follow-Ups

  <!-- Deferred work after this PR, or None. -->
  """

  @valid_body """
  #### Context

  Context text.

  #### TL;DR

  Short summary.

  #### Summary

  - First change.

  #### Alternatives

  - Alternative considered.

  #### Test Plan

  - [x] Ran targeted checks.

  #### Scope Contract

  ##### Work Item

  Enforce typed PR scope contracts.

  ##### Invariants

  - Existing generic PR body checks still run.

  ##### Acceptance Criteria

  - AC-1: Invalid scope contracts fail with all detected errors.

  ##### Non-Goals

  - Do not change review routing.

  ##### Dependencies

  None

  ##### Follow-Ups

  None
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix pr_body.check --file /path/to/pr_body.md"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["lint", "--wat"])
    end
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      Check.run(["lint"])
    end
  end

  test "fails when template is missing" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/Unable to read PR template/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when template has no headings" do
    in_temp_repo(fn ->
      write_template!("no headings here")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/No markdown headings found/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when body file is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      assert_raise Mix.Error, ~r/Unable to read missing\.md/, fn ->
        Check.run(["lint", "--file", "missing.md"])
      end
    end)
  end

  test "fails when body still has placeholders" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @template)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "PR description still contains template placeholder comments"
    end)
  end

  test "fails when heading is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heading = String.replace(@valid_body, "#### Alternatives\n\n- Alternative considered.\n\n", "")
      File.write!("body.md", missing_heading)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Missing required heading: #### Alternatives"
    end)
  end

  test "fails when headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      out_of_order = """
      #### TL;DR

      Short summary.

      #### Context

      Context text.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.
      """

      File.write!("body.md", out_of_order)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Required headings are out of order."
    end)
  end

  test "fails on empty section" do
    in_temp_repo(fn ->
      write_template!(@template)

      empty_context = String.replace(@valid_body, "Context text.", "")
      File.write!("body.md", empty_context)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "fails when a middle section is blank before the next heading" do
    in_temp_repo(fn ->
      write_template!(@template)

      blank_alternatives = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives


      #### Test Plan

      - [x] Ran targeted checks.
      """

      File.write!("body.md", blank_alternatives)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Alternatives"
    end)
  end

  test "fails when bullet and checkbox expectations are not met" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      Not a bullet.

      #### Alternatives

      Also not a bullet.

      #### Test Plan

      No checkbox.
      """

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include at least one bullet item: #### Summary"
      assert error_output =~ "Section must include at least one bullet item: #### Alternatives"
      assert error_output =~ "Section must include at least one bullet item: #### Test Plan"
      assert error_output =~ "Section must include at least one checkbox item: #### Test Plan"
    end)
  end

  test "fails when heading has no content delimiter" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context\nContext text.")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
          Check.run(["lint", "--file", "body.md"])
        end
      end)
    end)
  end

  test "fails when heading appears at end of file" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "passes for valid body" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "fails a complete body whose Work Item is bulleted None" do
    # Mutation caught: letting the Mix task accept bulleted None as real Work Item prose.
    in_temp_repo(fn ->
      write_template!(@template)

      body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.

      #### Scope Contract

      ##### Work Item

      - None

      ##### Invariants

      - Existing generic PR body checks still run.

      ##### Acceptance Criteria

      - AC-1: Invalid scope contracts fail with all detected errors.

      ##### Non-Goals

      - Do not change review routing.

      ##### Dependencies

      None

      ##### Follow-Ups

      None
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Scope Contract Work Item cannot be None"
    end)
  end

  test "fails a complete body whose Work Item is a blank bullet" do
    # Mutation caught: letting the Mix task accept a lone Markdown bullet as Work Item prose.
    in_temp_repo(fn ->
      write_template!(@template)

      body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.

      #### Scope Contract

      ##### Work Item

      -

      ##### Invariants

      - Existing generic PR body checks still run.

      ##### Acceptance Criteria

      - AC-1: Invalid scope contracts fail with all detected errors.

      ##### Non-Goals

      - Do not change review routing.

      ##### Dependencies

      None

      ##### Follow-Ups

      None
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Scope Contract Work Item contains a blank bullet"
    end)
  end

  test "fails a complete body whose Work Item is a populated bullet" do
    # Mutation caught: letting the Mix task accept Markdown list structure as Work Item prose.
    in_temp_repo(fn ->
      write_template!(@template)

      body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.

      #### Scope Contract

      ##### Work Item

      - Enforce typed PR scope contracts.

      ##### Invariants

      - Existing generic PR body checks still run.

      ##### Acceptance Criteria

      - AC-1: Invalid scope contracts fail with all detected errors.

      ##### Non-Goals

      - Do not change review routing.

      ##### Dependencies

      None

      ##### Follow-Ups

      None
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~
               "Scope Contract Work Item has malformed bullet: - Enforce typed PR scope contracts."
    end)
  end

  test "fails when a complete generic body omits a required scope contract field" do
    # Mutation caught: removing the shared ScopeContract parser call from the Mix task.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        String.replace(
          @valid_body,
          "##### Non-Goals\n\n- Do not change review routing.\n\n",
          ""
        )

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Missing Scope Contract section: Non-Goals"
    end)
  end

  test "fails when Scope Contract contains a duplicate subheading" do
    # Mutation caught: bypassing duplicate-section errors returned by the shared parser.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        String.replace(
          @valid_body,
          "##### Invariants\n\n- Existing generic PR body checks still run.\n\n",
          "##### Invariants\n\n- Existing generic PR body checks still run.\n\n##### Invariants\n\n- Duplicate scope rule.\n\n"
        )

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Duplicate Scope Contract section: Invariants"
    end)
  end

  test "formats every structural and semantic Scope Contract error in one real run" do
    # Mutations caught: dropping a typed formatter or stopping before all shared parser errors are printed.
    in_temp_repo(fn ->
      write_template!(@template)

      body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] Ran targeted checks.

      #### Scope Contract

      ##### Work Item

      Enforce typed PR scope contracts.
      Also change review routing.

      ##### Ownership

      - Symphony governance.

      ##### Invariants

      - Existing generic PR body checks still run.

      ##### Acceptance Criteria

      - Missing a stable identifier.
      - AC-1: Invalid scope contracts fail closed.
      - AC-1: Duplicate identifiers fail closed.

      ##### Non-Goals

      - Do not change review routing.

      ##### Dependencies


      ##### Follow-Ups

      - None
      - Add runtime routing later.

      #### Scope Contract
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Duplicate Scope Contract section."
      assert error_output =~ "Unexpected Scope Contract section: Ownership"
      assert error_output =~ "Scope Contract Dependencies cannot be empty"
      assert error_output =~ "Scope Contract Follow-Ups must use None by itself"

      assert error_output =~
               "Scope Contract Acceptance Criteria has malformed criterion: Missing a stable identifier."

      assert error_output =~ "Scope Contract Acceptance Criteria duplicates identifier: AC-1"
      assert error_output =~ "Scope Contract Work Item must contain exactly one value"
    end)
  end

  for {field, heading} <- [
        {"Invariants", "Invariants"},
        {"Acceptance Criteria", "Acceptance Criteria"},
        {"Non-Goals", "Non-Goals"}
      ] do
    test "fails when None is used for required Scope Contract #{field}" do
      # Mutation caught: accepting None for a required Scope Contract list field.
      in_temp_repo(fn ->
        write_template!(@template)

        body =
          String.replace(
            @valid_body,
            "##### #{unquote(heading)}\n\n" <> scope_contract_value(unquote(heading)) <> "\n\n",
            "##### #{unquote(heading)}\n\nNone\n\n"
          )

        File.write!("body.md", body)

        error_output = capture_invalid_body_output()

        assert error_output =~ "Scope Contract #{unquote(heading)} cannot be None"
      end)
    end
  end

  test "prints every scope contract error with generic errors in one run" do
    # Mutation caught: stopping after the first contract error or replacing generic lint errors.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        @valid_body
        |> String.replace("- First change.", "Summary without a bullet.")
        |> String.replace("- Existing generic PR body checks still run.", "None")
        |> String.replace("- AC-1: Invalid scope contracts fail with all detected errors.", "None")
        |> String.replace("- Do not change review routing.", "None")

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Section must include at least one bullet item: #### Summary"
      assert error_output =~ "Scope Contract Invariants cannot be None"
      assert error_output =~ "Scope Contract Acceptance Criteria cannot be None"
      assert error_output =~ "Scope Contract Non-Goals cannot be None"
    end)
  end

  defp capture_invalid_body_output do
    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  defp scope_contract_value("Invariants"), do: "- Existing generic PR body checks still run."

  defp scope_contract_value("Acceptance Criteria"),
    do: "- AC-1: Invalid scope contracts fail with all detected errors."

  defp scope_contract_value("Non-Goals"), do: "- Do not change review routing."

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "validate-pr-body-task-test-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_template!(content) do
    File.mkdir_p!(".github")
    File.write!(".github/pull_request_template.md", content)
  end
end
