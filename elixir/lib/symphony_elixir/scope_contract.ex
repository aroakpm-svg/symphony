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
    lines = pr_body |> String.replace("\r\n", "\n") |> String.split("\n")
    outer_headings = Enum.count(lines, &(String.trim_trailing(&1) == "#### Scope Contract"))

    case Enum.find_index(lines, &(String.trim_trailing(&1) == "#### Scope Contract")) do
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
    {sections, errors, _current} =
      Enum.reduce(lines, {%{}, [], nil}, &collect_section_line/2)

    {sections, errors}
  end

  defp collect_section_line(line, state) do
    case section_heading(line) do
      {:known, field} -> collect_known_section(field, state)
      {:unknown, heading} -> collect_unknown_section(heading, state)
      :content -> collect_section_content(line, state)
    end
  end

  defp collect_known_section(field, {sections, errors, _current}) do
    if Map.has_key?(sections, field) do
      {sections, errors ++ [{:duplicate_section, field}], :ignore}
    else
      {Map.put(sections, field, []), errors, field}
    end
  end

  defp collect_unknown_section(heading, {sections, errors, _current}) do
    {sections, errors ++ [{:unexpected_section, heading}], :ignore}
  end

  defp collect_section_content(line, {sections, errors, current} = state) do
    if Map.has_key?(sections, current) do
      {Map.update!(sections, current, &(&1 ++ [line])), errors, current}
    else
      state
    end
  end

  defp section_heading(line) do
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
            {Map.put(values, field, value), errors ++ field_errors}
        end
      end)

    {values, missing_errors ++ content_errors}
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

      values == ["None"] ->
        {"", [{:none_not_allowed, :work_item}]}

      length(values) == 1 ->
        {hd(values), []}

      true ->
        {"", [{:invalid_work_item, :multiple_values}]}
    end
  end

  defp validate_list(field, lines) do
    values = nonblank_lines(lines)

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
    {values, errors} = Enum.reduce(lines, {[], []}, &normalize_bullet(field, &1, &2))

    {values, errors}
  end

  defp normalize_bullet(_field, "None", {values, errors}), do: {values ++ ["None"], errors}

  defp normalize_bullet(field, "-", {values, errors}) do
    {values, errors ++ [{:blank_bullet, field}]}
  end

  defp normalize_bullet(field, <<"- ", value::binary>>, state) do
    append_normalized_bullet(field, String.trim(value), state)
  end

  defp normalize_bullet(field, line, {values, errors}) do
    {values, errors ++ [{:malformed_bullet, field, line}]}
  end

  defp append_normalized_bullet(field, "", {values, errors}) do
    {values, errors ++ [{:blank_bullet, field}]}
  end

  defp append_normalized_bullet(_field, value, {values, errors}), do: {values ++ [value], errors}

  defp validate_normalized_list(field, ["None"]) when field in @optional_none_fields, do: {[], []}

  defp validate_normalized_list(field, values) do
    cond do
      "None" in values ->
        {[], [{none_error(field), field}]}

      field == :acceptance_criteria ->
        {values, acceptance_criterion_errors(values)}

      true ->
        {values, []}
    end
  end

  defp acceptance_criterion_errors(values) do
    {_identifiers, errors} =
      Enum.reduce(values, {MapSet.new(), []}, &collect_acceptance_criterion/2)

    errors
  end

  defp collect_acceptance_criterion(value, {identifiers, errors}) do
    case acceptance_criterion_identifier(value) do
      {:ok, identifier} -> collect_acceptance_identifier(identifier, identifiers, errors)
      :error -> {identifiers, errors ++ [{:malformed_acceptance_criterion, value}]}
    end
  end

  defp collect_acceptance_identifier(identifier, identifiers, errors) do
    if MapSet.member?(identifiers, identifier) do
      {identifiers, errors ++ [{:duplicate_acceptance_criterion, identifier}]}
    else
      {MapSet.put(identifiers, identifier), errors}
    end
  end

  defp nonblank_lines(lines), do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp placeholder?(lines), do: Enum.any?(lines, &String.contains?(&1, "<!--"))
  defp none_error(field) when field in @required_list_fields, do: :none_not_allowed
  defp none_error(_field), do: :none_must_be_explicit

  defp acceptance_criterion_identifier(value) do
    case Regex.run(~r/^(AC-[1-9][0-9]*):\s+\S/, value) do
      [_, identifier] -> {:ok, identifier}
      nil -> :error
    end
  end

  defp level_four_heading?(line), do: String.starts_with?(String.trim_trailing(line), "#### ")
end
