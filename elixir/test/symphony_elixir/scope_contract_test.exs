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
end
