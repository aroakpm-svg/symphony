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

      lines ->
        {sections, structural_errors} = collect_sections(lines)
        {values, validation_errors} = validate_sections(sections)
        errors = structural_errors ++ validation_errors

        if errors == [] do
          {:ok, struct!(__MODULE__, values)}
        else
          {:error, errors}
        end
    end
  end

  defp scope_contract_lines(pr_body) do
    pr_body
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim_trailing(&1) != "#### Scope Contract"))
    |> case do
      [] -> :missing
      [_heading | remaining_lines] -> Enum.take_while(remaining_lines, &(not level_four_heading?(&1)))
    end
  end

  defp collect_sections(lines) do
    {sections, errors, _current} =
      Enum.reduce(lines, {%{}, [], nil}, fn line, {sections, errors, current} ->
        case section_heading(line) do
          {:known, field} ->
            if Map.has_key?(sections, field) do
              {sections, errors ++ [{:duplicate_section, field}], :ignore}
            else
              {Map.put(sections, field, []), errors, field}
            end

          {:unknown, heading} ->
            {sections, errors ++ [{:unexpected_section, heading}], :ignore}

          :content ->
            if Map.has_key?(sections, current) do
              {Map.update!(sections, current, &(&1 ++ [line])), errors, current}
            else
              {sections, errors, current}
            end
        end
      end)

    {sections, errors}
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

      values == ["None"] and field in @optional_none_fields ->
        {[], []}

      "None" in values ->
        {[], [{none_error(field), field}]}

      true ->
        normalize_bullets(field, values)
    end
  end

  defp normalize_bullets(field, lines) do
    {values, errors} =
      Enum.reduce(lines, {[], []}, fn line, {values, errors} ->
        case String.starts_with?(line, "-") do
          false ->
            {values, errors ++ [{:malformed_bullet, field, line}]}

          true ->
            value = line |> String.trim_leading("-") |> String.trim()

            if value == "" do
              {values, errors ++ [{:blank_bullet, field}]}
            else
              {values ++ [value], errors}
            end
        end
      end)

    acceptance_errors =
      if field == :acceptance_criteria do
        Enum.flat_map(values, fn value ->
          if stable_acceptance_criterion?(value), do: [], else: [{:malformed_acceptance_criterion, value}]
        end)
      else
        []
      end

    {values, errors ++ acceptance_errors}
  end

  defp nonblank_lines(lines), do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp placeholder?(lines), do: Enum.any?(lines, &String.contains?(&1, "<!--"))
  defp none_error(field) when field in @required_list_fields, do: :none_not_allowed
  defp none_error(_field), do: :none_must_be_explicit
  defp stable_acceptance_criterion?(value), do: Regex.match?(~r/^AC-[1-9][0-9]*:\s+\S/, value)
  defp level_four_heading?(line), do: String.starts_with?(String.trim_trailing(line), "#### ")
end
