defmodule SymphonyElixir.ScopeContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ScopeContract

  @complete_contract """
  #### Scope Contract

  ##### Work Item

  Add a typed PR scope contract parser.

  ##### Invariants

  - The parser reads only explicit Scope Contract headings.
  - Invalid contracts fail closed.

  ##### Acceptance Criteria

  - AC-1: Parse a complete scope contract.
  - AC-2: Aggregate validation errors.

  ##### Non-Goals

  - Do not change review routing.

  ##### Dependencies

  None

  ##### Follow-Ups

  None
  """

  test "returns a typed contract for every complete field" do
    # Mutation caught: returning a map, dropping a field, or mapping a section to the wrong field.
    assert {:ok, contract} = ScopeContract.parse_pr_body(@complete_contract)

    assert %{
             __struct__: ScopeContract,
             work_item: "Add a typed PR scope contract parser.",
             invariants: [
               "The parser reads only explicit Scope Contract headings.",
               "Invalid contracts fail closed."
             ],
             acceptance_criteria: [
               "AC-1: Parse a complete scope contract.",
               "AC-2: Aggregate validation errors."
             ],
             non_goals: ["Do not change review routing."],
             dependencies: [],
             follow_ups: []
           } = contract
  end

  test "returns a stable error when a required section is missing" do
    # Mutation caught: skipping required Work Item heading validation and returning a partial contract.
    body = """
    #### Scope Contract

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:missing_section, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "returns a stable error when a required list section is missing" do
    # Mutation caught: omitting Invariants from the required-section validation list.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:missing_section, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate Scope Contract headings" do
    # Mutation caught: accepting the first duplicate Invariants section instead of failing closed.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - The parser reads only explicit Scope Contract headings.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:duplicate_section, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects blank bullets and HTML placeholder comments" do
    # Mutation caught: normalizing an empty bullet or template comment into usable contract data.
    body = """
    #### Scope Contract

    ##### Work Item

    <!-- Describe the work item. -->

    ##### Invariants

    -

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:placeholder_comment, :work_item}, {:blank_bullet, :invariants}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "accepts None only for Dependencies and Follow-Ups" do
    # Mutation caught: treating None as an empty value for required invariant, criterion, or non-goal lists.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    None

    ##### Acceptance Criteria

    None

    ##### Non-Goals

    None

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:none_not_allowed, :invariants},
              {:none_not_allowed, :acceptance_criteria},
              {:none_not_allowed, :non_goals}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects bulleted None as a Work Item" do
    # Mutation caught: accepting a Markdown bullet as the single Work Item prose value.
    body = """
    #### Scope Contract

    ##### Work Item

    - None

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_not_allowed, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects explicit None as a Work Item" do
    # Mutation caught: treating Work Item like an optional list that permits the None marker.
    body = """
    #### Scope Contract

    ##### Work Item

    None

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_not_allowed, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects a blank Markdown bullet as a Work Item" do
    # Mutation caught: accepting a lone Markdown bullet as the single Work Item prose value.
    body = """
    #### Scope Contract

    ##### Work Item

    -

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:blank_bullet, :work_item}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects a populated Markdown bullet as a Work Item" do
    # Mutation caught: stripping a Markdown bullet into apparently valid Work Item prose.
    body = """
    #### Scope Contract

    ##### Work Item

    - Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_bullet, :work_item, "- Add a typed PR scope contract parser."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "rejects multiple prose values as a Work Item" do
    # Mutation caught: silently selecting one of multiple nonblank Work Item lines.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.
    Also change review routing.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:invalid_work_item, :multiple_values}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "rejects an unexpected Scope Contract subheading" do
    # Mutation caught: ignoring unknown structured fields that could hide an authoring mistake.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Ownership

    - Symphony governance.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:unexpected_section, "Ownership"}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects an acceptance criterion without a stable identifier" do
    # Mutation caught: accepting free-form acceptance-criteria bullets without an AC identifier.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_acceptance_criterion, "Parse a complete scope contract."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "normalizes bullet None before required and optional list policies" do
    # Mutation caught: checking None before bullet normalization, which accepts required - None values.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - None

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None

    ##### Follow-Ups

    - None
    """

    assert {:error, [{:none_not_allowed, :invariants}]} = ScopeContract.parse_pr_body(body)
  end

  test "accepts bullet None as an explicit empty optional list" do
    # Mutation caught: treating normalized - None as a dependency value rather than the optional empty marker.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None

    ##### Follow-Ups

    - None
    """

    assert {:ok, %{dependencies: [], follow_ups: []}} = ScopeContract.parse_pr_body(body)
  end

  test "rejects mixed None and ordinary optional list values" do
    # Mutation caught: allowing None to coexist with a real dependency after bullet normalization.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None
    - Existing PR lint.

    ##### Follow-Ups

    None
    """

    assert {:error, [{:none_must_be_explicit, :dependencies}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects hyphen-prefixed text that is not a Markdown bullet" do
    # Mutation caught: stripping every leading hyphen and accepting -value or --value as list bullets.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    -value
    --value

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "-value"},
              {:malformed_bullet, :invariants, "--value"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate outer Scope Contract headings" do
    # Mutation caught: parsing only the first outer Scope Contract and silently ignoring a second contract.
    body = @complete_contract <> "\n#### Scope Contract\n\n##### Work Item\n\nConflicting contract.\n"

    assert {:error, [{:duplicate_scope_contract}]} = ScopeContract.parse_pr_body(body)
  end

  test "rejects duplicate stable acceptance-criterion identifiers" do
    # Mutation caught: validating AC syntax without detecting repeated stable identifiers.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.
    - AC-1: Aggregate validation errors.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:duplicate_acceptance_criterion, "AC-1"}]} = ScopeContract.parse_pr_body(body)
  end

  test "aggregates malformed bullets and malformed acceptance criteria from one list" do
    # Mutation caught: returning structural bullet errors before validating usable acceptance-criteria entries.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    malformed bullet
    - Missing a stable identifier.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :acceptance_criteria, "malformed bullet"},
              {:malformed_acceptance_criterion, "Missing a stable identifier."}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "aggregates malformed bullets and required None policy errors from one list" do
    # Mutation caught: skipping required None policy validation after a sibling bullet normalization error.
    body = """
    #### Scope Contract

    ##### Work Item

    Add a typed PR scope contract parser.

    ##### Invariants

    malformed bullet
    - None

    ##### Acceptance Criteria

    - AC-1: Parse a complete scope contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "malformed bullet"},
              {:none_not_allowed, :invariants}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "ignores Scope Contract headings inside backtick and tilde fences" do
    # Mutation caught: counting fenced example headings or closing a fence with a shorter marker.
    body = """
    #### Context

    ````markdown
    #### Scope Contract
    ```
    #### Scope Contract
    ````

    ~~~~ text
    #### Scope Contract
    ~~~
    #### Scope Contract
    ~~~~~

    #### Scope Contract

    ##### Work Item

    Parse the real scope contract.

    ##### Invariants

    - Fenced examples do not create contracts.

    ##### Acceptance Criteria

    - AC-1: Parse the visible contract heading.

    ##### Non-Goals

    - Do not interpret prose semantically.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:ok,
            %{
              work_item: "Parse the real scope contract.",
              invariants: ["Fenced examples do not create contracts."],
              acceptance_criteria: ["AC-1: Parse the visible contract heading."]
            }} = ScopeContract.parse_pr_body(body)
  end

  test "keeps fenced headings inside a real list section as fail-closed content" do
    # Mutation caught: treating fenced ##### as a section or fenced #### as a scope terminator.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse the real scope contract.

    ##### Invariants

    - Keep parsing the visible contract.
    ```markdown
    ##### Acceptance Criteria
    #### Premature Terminator
    ```
    - Keep parsing after the fenced example.

    ##### Acceptance Criteria

    - AC-1: Parse all visible sections.

    ##### Non-Goals

    - Do not interpret fenced headings as structure.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "```markdown"},
              {:malformed_bullet, :invariants, "##### Acceptance Criteria"},
              {:malformed_bullet, :invariants, "#### Premature Terminator"},
              {:malformed_bullet, :invariants, "```"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "joins legally indented Markdown list continuations" do
    # Mutation caught: requiring every physical line of one list item to repeat the bullet marker.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse wrapped contract values.

    ##### Invariants

    - Invalid contracts remain
      fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse legal Markdown
        continuation indentation.

    ##### Non-Goals

    - Do not change
      review routing.

    ##### Dependencies

    - Existing PR lint
      integration.

    ##### Follow-Ups

    None
    """

    assert {:ok,
            %{
              invariants: ["Invalid contracts remain fail closed."],
              acceptance_criteria: ["AC-1: Parse legal Markdown continuation indentation."],
              non_goals: ["Do not change review routing."],
              dependencies: ["Existing PR lint integration."]
            }} = ScopeContract.parse_pr_body(body)
  end

  test "rejects an indented continuation before the first list bullet" do
    # Mutation caught: accepting an orphan continuation merely because it has legal continuation indentation.
    body = """
    #### Scope Contract

    ##### Work Item

    Parse wrapped contract values.

    ##### Invariants

      Orphaned continuation.
    - Invalid contracts remain
      fail closed.

    ##### Acceptance Criteria

    - AC-1: Parse a complete contract.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error, [{:malformed_bullet, :invariants, "Orphaned continuation."}]} =
             ScopeContract.parse_pr_body(body)
  end

  test "aggregates None and all remaining acceptance criterion errors in stable order" do
    # Mutation caught: returning the None policy error before validating other usable acceptance criteria.
    body = """
    #### Scope Contract

    ##### Work Item

    Aggregate all criterion errors.

    ##### Invariants

    - Invalid contracts fail closed.

    ##### Acceptance Criteria

    - None
    - Missing a stable identifier.
    - AC-1: First criterion.
    - AC-1: Duplicate criterion.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:none_not_allowed, :acceptance_criteria},
              {:malformed_acceptance_criterion, "Missing a stable identifier."},
              {:duplicate_acceptance_criterion, "AC-1"}
            ]} = ScopeContract.parse_pr_body(body)
  end

  @tag timeout: 2_500
  test "parses a large contract in stable source order without quadratic accumulation" do
    # Mutation caught: appending each parsed line to the accumulated list and repeatedly copying its prefix.
    bullets = Enum.map_join(1..40_000, "\n", fn index -> "- invariant #{index}" end)

    body = """
    #### Scope Contract

    ##### Work Item

    Parse a large scope contract.

    ##### Invariants

    #{bullets}

    ##### Acceptance Criteria

    - AC-1: Preserve source order.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:ok, %{invariants: invariants}} = ScopeContract.parse_pr_body(body)
    assert length(invariants) == 40_000
    assert hd(invariants) == "invariant 1"
    assert List.last(invariants) == "invariant 40000"
  end

  test "keeps None typed when a continuation follows in required and optional lists" do
    # Mutation caught: rewriting the None sentinel into ordinary text when an indented continuation follows it.
    body = """
    #### Scope Contract

    ##### Work Item

    Preserve typed normalized items.

    ##### Invariants

    - None
      must remain a sentinel.

    ##### Acceptance Criteria

    - AC-1: Fail closed on invalid sentinel continuations.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    - None
      must remain standalone.

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "must remain a sentinel."},
              {:none_not_allowed, :invariants},
              {:malformed_bullet, :dependencies, "must remain standalone."},
              {:none_must_be_explicit, :dependencies}
            ]} = ScopeContract.parse_pr_body(body)
  end

  test "does not consume indented Markdown block starts as paragraph continuations" do
    # Mutation caught: classifying every indented line as wrapped prose regardless of Markdown block structure.
    body = """
    #### Scope Contract

    ##### Work Item

    Preserve Markdown list structure.

    ##### Invariants

    - Keep the first invariant.
      - Nested dash item.
      * Alternate star item.
      + Alternate plus item.
      1. Ordered item.
      ## ATX heading.
      > Block quote.

    ##### Acceptance Criteria

    - AC-1: Reject nested Markdown blocks.

    ##### Non-Goals

    - Do not change review routing.

    ##### Dependencies

    None

    ##### Follow-Ups

    None
    """

    assert {:error,
            [
              {:malformed_bullet, :invariants, "- Nested dash item."},
              {:malformed_bullet, :invariants, "* Alternate star item."},
              {:malformed_bullet, :invariants, "+ Alternate plus item."},
              {:malformed_bullet, :invariants, "1. Ordered item."},
              {:malformed_bullet, :invariants, "## ATX heading."},
              {:malformed_bullet, :invariants, "> Block quote."}
            ]} = ScopeContract.parse_pr_body(body)
  end
end
