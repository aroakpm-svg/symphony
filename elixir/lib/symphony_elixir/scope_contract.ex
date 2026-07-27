defmodule SymphonyElixir.ScopeContract do
  @moduledoc """
  Parses the structured Scope Contract section of a pull-request body.
  """

  @fields [
    {:work_item, "Work Item"},
    {:invariants, "Invariants"},
    {:acceptance_criteria, "Acceptance Criteria"},
    {:non_goals, "Non-Goals"},
    {:dependencies, "Dependencies"},
    {:follow_ups, "Follow-Ups"}
  ]

  @optional_none_fields [:dependencies, :follow_ups]
  @required_list_fields [:invariants, :acceptance_criteria, :non_goals]
  @scope_contract_heading "#### Scope Contract"
  @opening_fence ~r/^( {0,3})(`{3,}|~{3,})(.*)$/
  @closing_fence ~r/^( {0,3})(`{3,}|~{3,})[ \t]*$/

  @enforce_keys [:work_item, :invariants, :acceptance_criteria, :non_goals, :dependencies, :follow_ups]
  defstruct [:work_item, :invariants, :acceptance_criteria, :non_goals, :dependencies, :follow_ups]

  @type field :: :work_item | :invariants | :acceptance_criteria | :non_goals | :dependencies | :follow_ups

  @type error ::
          :missing_scope_contract
          | {:duplicate_scope_contract}
          | {:missing_section, field()}
          | {:duplicate_section, field()}
          | {:unexpected_section, String.t()}
          | {:placeholder_comment, field()}
          | {:blank_bullet, field()}
          | {:none_not_allowed, field()}
          | {:none_must_be_explicit, field()}
          | {:empty_section, field()}
          | {:malformed_bullet, field(), String.t()}
          | {:malformed_acceptance_criterion, String.t()}
          | {:duplicate_acceptance_criterion, String.t()}
          | {:invalid_work_item, :multiple_values}

  @type t :: %__MODULE__{
          work_item: String.t(),
          invariants: [String.t()],
          acceptance_criteria: [String.t()],
          non_goals: [String.t()],
          dependencies: [String.t()],
          follow_ups: [String.t()]
        }

  @spec parse_pr_body(String.t()) :: {:ok, t()} | {:error, [error()]}
  def parse_pr_body(pr_body) do
    case scope_contract_lines(pr_body) do
      :missing ->
        {:error, [:missing_scope_contract]}

      {lines, outer_errors} ->
        {sections, structural_errors} = collect_sections(lines)
        {values, validation_errors} = validate_sections(sections)
        errors = outer_errors ++ structural_errors ++ validation_errors

        if errors == [] do
          {:ok, struct!(__MODULE__, values)}
        else
          {:error, errors}
        end
    end
  end

  defp scope_contract_lines(pr_body) do
    lines =
      pr_body
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> mark_fenced_lines()

    outer_headings = Enum.count(lines, &scope_contract_heading?/1)

    case Enum.find_index(lines, &scope_contract_heading?/1) do
      nil ->
        :missing

      index ->
        errors = if outer_headings > 1, do: [{:duplicate_scope_contract}], else: []

        scope_lines =
          lines
          |> Enum.drop(index + 1)
          |> Enum.take_while(&(not level_four_heading?(&1)))

        {scope_lines, errors}
    end
  end

  defp collect_sections(lines) do
    {reversed_sections, reversed_errors, _current} =
      Enum.reduce(lines, {%{}, [], nil}, &collect_section_line/2)

    sections = Map.new(reversed_sections, fn {field, section_lines} -> {field, Enum.reverse(section_lines)} end)
    {sections, Enum.reverse(reversed_errors)}
  end

  defp collect_section_line({line, fenced?}, state) do
    case section_heading(line, fenced?) do
      {:known, field} -> collect_known_section(field, state)
      {:unknown, heading} -> collect_unknown_section(heading, state)
      :content -> collect_section_content(line, state)
    end
  end

  defp collect_known_section(field, {sections, errors, _current}) do
    if Map.has_key?(sections, field) do
      {sections, [{:duplicate_section, field} | errors], :ignore}
    else
      {Map.put(sections, field, []), errors, field}
    end
  end

  defp collect_unknown_section(heading, {sections, errors, _current}) do
    {sections, [{:unexpected_section, heading} | errors], :ignore}
  end

  defp collect_section_content(line, {sections, errors, current} = state) do
    if Map.has_key?(sections, current) do
      {Map.update!(sections, current, &[line | &1]), errors, current}
    else
      state
    end
  end

  defp section_heading(_line, true), do: :content

  defp section_heading(line, false) do
    trimmed = String.trim_trailing(line)

    case Enum.find(@fields, fn {_field, title} -> trimmed == "##### #{title}" end) do
      {field, _title} ->
        {:known, field}

      nil ->
        if String.starts_with?(trimmed, "##### ") do
          {:unknown, String.trim_leading(trimmed, "##### ")}
        else
          :content
        end
    end
  end

  defp validate_sections(sections) do
    missing_errors =
      for {field, _title} <- @fields, not Map.has_key?(sections, field), do: {:missing_section, field}

    {values, content_errors} =
      Enum.reduce(@fields, {%{}, []}, fn {field, _title}, {values, errors} ->
        case Map.fetch(sections, field) do
          :error ->
            {values, errors}

          {:ok, lines} ->
            {value, field_errors} = validate_field(field, lines)
            {Map.put(values, field, value), Enum.reverse(field_errors, errors)}
        end
      end)

    {values, missing_errors ++ Enum.reverse(content_errors)}
  end

  defp validate_field(:work_item, lines), do: validate_work_item(lines)
  defp validate_field(field, lines), do: validate_list(field, lines)

  defp validate_work_item(lines) do
    values = nonblank_lines(lines)

    cond do
      placeholder?(values) ->
        {"", [{:placeholder_comment, :work_item}]}

      values == [] ->
        {"", [{:empty_section, :work_item}]}

      length(values) == 1 ->
        validate_work_item_value(hd(values))

      true ->
        {"", [{:invalid_work_item, :multiple_values}]}
    end
  end

  defp validate_work_item_value("None"), do: {"", [{:none_not_allowed, :work_item}]}
  defp validate_work_item_value("- None"), do: {"", [{:none_not_allowed, :work_item}]}
  defp validate_work_item_value("-"), do: {"", [{:blank_bullet, :work_item}]}

  defp validate_work_item_value(<<"- ", _value::binary>> = value),
    do: {"", [{:malformed_bullet, :work_item, value}]}

  defp validate_work_item_value(value), do: {value, []}

  defp validate_list(field, lines) do
    values = nonblank_list_lines(lines)

    cond do
      placeholder?(values) ->
        {[], [{:placeholder_comment, field}]}

      values == [] ->
        {[], [{:empty_section, field}]}

      true ->
        {normalized_values, normalization_errors} = normalize_bullets(field, values)
        {normalized_value, semantic_errors} = validate_normalized_list(field, normalized_values)
        {normalized_value, normalization_errors ++ semantic_errors}
    end
  end

  defp normalize_bullets(field, lines) do
    {reversed_values, reversed_errors} = Enum.reduce(lines, {[], []}, &normalize_bullet(field, &1, &2))

    {Enum.reverse(reversed_values), Enum.reverse(reversed_errors)}
  end

  defp normalize_bullet(field, line, state) do
    normalize_bullet_value(field, line, String.trim(line), state)
  end

  defp normalize_bullet_value(_field, _line, "None", {values, errors}), do: {["None" | values], errors}

  defp normalize_bullet_value(field, _line, "-", {values, errors}) do
    {values, [{:blank_bullet, field} | errors]}
  end

  defp normalize_bullet_value(_field, _line, <<"- ", value::binary>>, {values, errors}) do
    {[String.trim(value) | values], errors}
  end

  defp normalize_bullet_value(field, _line, <<"-", _rest::binary>> = value, {values, errors}) do
    {values, [{:malformed_bullet, field, value} | errors]}
  end

  defp normalize_bullet_value(field, line, value, state) do
    if continuation_line?(line) do
      append_continuation(field, value, state)
    else
      malformed_bullet(field, value, state)
    end
  end

  defp append_continuation(_field, value, {[previous | values], errors}) do
    {[previous <> " " <> value | values], errors}
  end

  defp append_continuation(field, value, {[], errors}) do
    {[], [{:malformed_bullet, field, value} | errors]}
  end

  defp malformed_bullet(field, value, {values, errors}) do
    {values, [{:malformed_bullet, field, value} | errors]}
  end

  defp validate_normalized_list(field, ["None"]) when field in @optional_none_fields, do: {[], []}

  defp validate_normalized_list(:acceptance_criteria, values) do
    criterion_values = Enum.reject(values, &(&1 == "None"))
    criterion_errors = acceptance_criterion_errors(criterion_values)

    if "None" in values do
      {[], [{:none_not_allowed, :acceptance_criteria} | criterion_errors]}
    else
      {values, criterion_errors}
    end
  end

  defp validate_normalized_list(field, values) do
    if "None" in values do
      {[], [{none_error(field), field}]}
    else
      {values, []}
    end
  end

  defp acceptance_criterion_errors(values) do
    {_identifiers, reversed_errors} =
      Enum.reduce(values, {MapSet.new(), []}, &collect_acceptance_criterion/2)

    Enum.reverse(reversed_errors)
  end

  defp collect_acceptance_criterion(value, {identifiers, errors}) do
    case acceptance_criterion_identifier(value) do
      {:ok, identifier} -> collect_acceptance_identifier(identifier, identifiers, errors)
      :error -> {identifiers, [{:malformed_acceptance_criterion, value} | errors]}
    end
  end

  defp collect_acceptance_identifier(identifier, identifiers, errors) do
    if MapSet.member?(identifiers, identifier) do
      {identifiers, [{:duplicate_acceptance_criterion, identifier} | errors]}
    else
      {MapSet.put(identifiers, identifier), errors}
    end
  end

  defp nonblank_lines(lines), do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp nonblank_list_lines(lines), do: lines |> Enum.map(&String.trim_trailing/1) |> Enum.reject(&(String.trim(&1) == ""))
  defp placeholder?(lines), do: Enum.any?(lines, &String.contains?(&1, "<!--"))
  defp none_error(field) when field in @required_list_fields, do: :none_not_allowed
  defp none_error(_field), do: :none_must_be_explicit

  defp mark_fenced_lines(lines) do
    {marked_lines, _fence} = Enum.map_reduce(lines, nil, &mark_fenced_line/2)
    marked_lines
  end

  defp mark_fenced_line(line, nil) do
    case opening_fence(line) do
      {:ok, fence} -> {{line, true}, fence}
      :none -> {{line, false}, nil}
    end
  end

  defp mark_fenced_line(line, fence) do
    next_fence = if closing_fence?(line, fence), do: nil, else: fence
    {{line, true}, next_fence}
  end

  defp opening_fence(line) do
    case Regex.run(@opening_fence, line) do
      [_, _indent, marker, info] -> validate_opening_fence(marker, info)
      nil -> :none
    end
  end

  defp validate_opening_fence(<<"`", _rest::binary>> = marker, info) do
    if String.contains?(info, "`"), do: :none, else: {:ok, {"`", String.length(marker)}}
  end

  defp validate_opening_fence(marker, _info), do: {:ok, {"~", String.length(marker)}}

  defp closing_fence?(line, {character, opening_length}) do
    case Regex.run(@closing_fence, line) do
      [_, _indent, marker] -> String.starts_with?(marker, character) and String.length(marker) >= opening_length
      nil -> false
    end
  end

  defp scope_contract_heading?({line, false}), do: String.trim_trailing(line) == @scope_contract_heading
  defp scope_contract_heading?({_line, true}), do: false

  defp continuation_line?(line), do: Regex.match?(~r/^(?: {2,}| *\t)/, line)

  defp acceptance_criterion_identifier(value) do
    case Regex.run(~r/^(AC-[1-9][0-9]*):\s+\S/, value) do
      [_, identifier] -> {:ok, identifier}
      nil -> :error
    end
  end

  defp level_four_heading?({line, false}), do: String.starts_with?(String.trim_trailing(line), "#### ")
  defp level_four_heading?({_line, true}), do: false
end
