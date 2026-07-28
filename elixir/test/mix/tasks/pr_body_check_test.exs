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

  test "uses shared continuation parsing and aggregates all acceptance criterion errors" do
    # Mutation caught: bypassing shared list normalization or short-circuiting semantic errors in the Mix task.
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

      ##### Invariants

      - Existing generic PR body checks
        still run.

      ##### Acceptance Criteria

      - None
      - Missing a stable identifier.
      - AC-1: Invalid contracts fail closed.
      - AC-1: Duplicate identifiers fail closed.

      ##### Non-Goals

      - Do not change review routing.

      ##### Dependencies

      None

      ##### Follow-Ups

      None
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      refute error_output =~ "Scope Contract Invariants has malformed bullet"
      assert error_output =~ "Scope Contract Acceptance Criteria cannot be None"

      assert error_output =~
               "Scope Contract Acceptance Criteria has malformed criterion: Missing a stable identifier."

      assert error_output =~ "Scope Contract Acceptance Criteria duplicates identifier: AC-1"
    end)
  end

  test "fails closed for None continuations and indented Markdown blocks through the shared parser" do
    # Mutation caught: flattening typed None or nested Markdown structures before Mix formats parser errors.
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

      ##### Invariants

      - None
        must remain a sentinel.

      ##### Acceptance Criteria

      - AC-1: Invalid scope contracts fail closed.

      ##### Non-Goals

      - Do not change review routing.
        * Nested Markdown block.

      ##### Dependencies

      - None
        must remain standalone.

      ##### Follow-Ups

      None
      """

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      assert error_output =~ "Scope Contract Invariants has malformed bullet: must remain a sentinel."
      assert error_output =~ "Scope Contract Invariants cannot be None"
      assert error_output =~ "Scope Contract Non-Goals has malformed bullet: * Nested Markdown block."
      assert error_output =~ "Scope Contract Dependencies has malformed bullet: must remain standalone."
      assert error_output =~ "Scope Contract Dependencies must use None by itself"
    end)
  end

  test "rejects reordered real Scope Contract headings despite ordered inline heading text" do
    # Mutation caught: trusting unanchored raw-body heading matches instead of the parser's visible heading tokens.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        @valid_body
        |> String.replace(
          "Enforce typed PR scope contracts.",
          "Enforce typed PR scope contracts while documenting `##### Invariants`, `##### Acceptance Criteria`, `##### Non-Goals`, `##### Dependencies`, and `##### Follow-Ups`."
        )
        |> String.replace(
          "##### Invariants\n\n- Existing generic PR body checks still run.\n\n##### Acceptance Criteria\n\n- AC-1: Invalid scope contracts fail with all detected errors.\n\n",
          "##### Acceptance Criteria\n\n- AC-1: Invalid scope contracts fail with all detected errors.\n\n##### Invariants\n\n- Existing generic PR body checks still run.\n\n"
        )

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()

      refute error_output =~ "Required headings are out of order."
      assert error_output =~ "Scope Contract sections are out of order."
    end)
  end

  test "ignores an inline H4 heading name before the real template heading" do
    # Mutation caught: locating required headings by arbitrary substring instead of visible line-level H4 tokens.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        String.replace(
          @valid_body,
          "Context text.",
          "Context text explains the literal `#### Scope Contract` heading before the real section."
        )

      File.write!("body.md", body)

      output = capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end)
      assert output =~ "PR body format OK"
    end)
  end

  test "rejects every non-dash Work Item list marker through the shared parser" do
    # Mutation caught: formatting only dash-list errors while alternate and ordered markers parse as prose.
    in_temp_repo(fn ->
      write_template!(@template)

      Enum.each(
        [
          "* Alternate bullet Work Item.",
          "+ Alternate bullet Work Item.",
          "1. Ordered Work Item.",
          "1) Parenthesized ordered Work Item."
        ],
        fn marker ->
          body = String.replace(@valid_body, "Enforce typed PR scope contracts.", marker)
          File.write!("body.md", body)

          error_output = capture_invalid_body_output()
          assert error_output =~ "Scope Contract Work Item has malformed bullet: #{marker}"
        end
      )
    end)
  end

  test "rejects thematic breaks in required lists through the shared parser" do
    # Mutation caught: letting canonical dash normalization hide a CommonMark thematic break from Mix output.
    in_temp_repo(fn ->
      write_template!(@template)

      Enum.each(["- - -", "-  -  -", "---", "***", "* * *", "___", "_ _ _"], fn thematic_break ->
        body =
          String.replace(
            @valid_body,
            "- Existing generic PR body checks still run.",
            thematic_break
          )

        File.write!("body.md", body)

        error_output = capture_invalid_body_output()
        assert error_output =~ "Scope Contract Invariants has malformed bullet: #{thematic_break}"
      end)
    end)
  end

  test "ignores reverse-ordered inline H5 names in the legacy raw heading order check" do
    # Mutation caught: letting unanchored H5 matches override the canonical Scope Contract heading sequence.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        String.replace(
          @valid_body,
          "Enforce typed PR scope contracts.",
          "Enforce typed PR scope contracts while documenting `##### Follow-Ups`, `##### Dependencies`, `##### Non-Goals`, `##### Acceptance Criteria`, and `##### Invariants`."
        )

      File.write!("body.md", body)

      output = capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end)
      assert output =~ "PR body format OK"
    end)
  end

  test "accepts canonical Scope headings with standard ATX closing hashes" do
    # Mutation caught: canonicalizing closing hashes only in parser tests but not at the real Mix entry.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        Enum.reduce(
          [
            {"#### Scope Contract", "#### Scope Contract ####"},
            {"##### Work Item", "##### Work Item #####"},
            {"##### Invariants", "##### Invariants #####"},
            {"##### Acceptance Criteria", "##### Acceptance Criteria #####"},
            {"##### Non-Goals", "##### Non-Goals #####"},
            {"##### Dependencies", "##### Dependencies #####"},
            {"##### Follow-Ups", "##### Follow-Ups #####"}
          ],
          @valid_body,
          fn {heading, closing_heading}, body -> String.replace(body, heading, closing_heading) end
        )

      File.write!("body.md", body)

      output = capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end)
      assert output =~ "PR body format OK"
    end)
  end

  test "reports indented code at Work Item and list boundaries through the shared parser" do
    # Mutation caught: losing indented-code token kinds before the real Mix formatter consumes parser errors.
    in_temp_repo(fn ->
      write_template!(@template)

      cases = [
        {
          String.replace(
            @valid_body,
            "Enforce typed PR scope contracts.",
            "    IO.puts(\"not Work Item prose\")"
          ),
          "Scope Contract Work Item has malformed bullet: IO.puts(\"not Work Item prose\")"
        },
        {
          String.replace(
            @valid_body,
            "- Existing generic PR body checks still run.",
            "- Existing generic PR body checks still run.\n      IO.puts(\"not continuation prose\")"
          ),
          "Scope Contract Invariants has malformed bullet: IO.puts(\"not continuation prose\")"
        }
      ]

      Enum.each(cases, fn {body, expected_error} ->
        File.write!("body.md", body)
        assert capture_invalid_body_output() =~ expected_error
      end)
    end)
  end

  test "does not collect outside H5 fields after a visible H1-H4 Scope boundary" do
    # Mutation caught: checking outer headings only at H4 and letting later H5 tokens complete the contract.
    in_temp_repo(fn ->
      write_template!(@template)

      body =
        String.replace(
          @valid_body,
          "##### Acceptance Criteria\n\n",
          "### Outside Scope\n\n##### Acceptance Criteria\n\n"
        )

      File.write!("body.md", body)

      error_output = capture_invalid_body_output()
      assert error_output =~ "Missing Scope Contract section: Acceptance Criteria"
      assert error_output =~ "Missing Scope Contract section: Follow-Ups"
    end)
  end

  test "formats an empty visible H5 as a malformed Scope section heading" do
    # Mutation caught: dropping malformed H5 tokens before the Mix task formats parser errors.
    in_temp_repo(fn ->
      write_template!(@template)

      body = String.replace(@valid_body, "#### Scope Contract\n\n", "#### Scope Contract\n\n#####\n\n")
      File.write!("body.md", body)

      assert capture_invalid_body_output() =~ "Malformed Scope Contract section heading: #####"
    end)
  end

  test "preserves invalid fence-marker and tab-indentation semantics at the real Mix entry" do
    # Mutations caught: flattening invalid fence markers or tabs into ordinary Scope Contract prose.
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_cases = [
        {
          String.replace(
            @valid_body,
            "- Existing generic PR body checks still run.",
            "- Existing generic PR body checks still run.\n  ```bad`info"
          ),
          "Scope Contract Invariants has malformed bullet: ```bad`info"
        },
        {
          String.replace(
            @valid_body,
            "Enforce typed PR scope contracts.",
            "\tIO.puts(\"tab-indented Work Item code\")"
          ),
          "Scope Contract Work Item has malformed bullet: IO.puts(\"tab-indented Work Item code\")"
        },
        {
          String.replace(
            @valid_body,
            "- Existing generic PR body checks still run.",
            "- Existing generic PR body checks still run.\n\t\tIO.puts(\"nested tab code\")"
          ),
          "Scope Contract Invariants has malformed bullet: IO.puts(\"nested tab code\")"
        }
      ]

      Enum.each(invalid_cases, fn {body, expected_error} ->
        File.write!("body.md", body)
        assert capture_invalid_body_output() =~ expected_error
      end)

      valid_continuation =
        String.replace(
          @valid_body,
          "- Existing generic PR body checks still run.",
          "- Existing generic PR body checks still run.\n\tthrough one tab stop."
        )

      File.write!("body.md", valid_continuation)
      assert capture_io(fn -> Check.run(["lint", "--file", "body.md"]) end) =~ "PR body format OK"
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
