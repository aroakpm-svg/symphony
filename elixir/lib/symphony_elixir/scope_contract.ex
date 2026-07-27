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

  @field_order Enum.map(@fields, &elem(&1, 0))
  @field_ranks @field_order |> Enum.with_index() |> Map.new()

  @optional_none_fields [:dependencies, :follow_ups]
  @required_list_fields [:invariants, :acceptance_criteria, :non_goals]
  @opening_fence ~r/^( {0,3})(`{3,}|~{3,})(.*)$/
  @closing_fence ~r/^( {0,3})(`{3,}|~{3,})[ \t]*$/
  @continuation_indent ~r/^(?: {2,}| *\t)/
  @thematic_break ~r/^(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/
  @atx_heading ~r/^(?<marker>[#]{1,6})(?:[ \t]+(?<content>.*))?$/
  @unordered_list ~r/^(?<marker>[*+-])(?:[ \t]+(?<content>.*))?$/
  @ordered_list ~r/^(?<marker>\d{1,9}[.)])(?:[ \t]+(?<content>.*))?$/
  @blockquote ~r/^>.*/
  @fence_marker ~r/^(?:`{3,}|~{3,}).*$/
  @markdown_structures [
    thematic_break: @thematic_break,
    heading: @atx_heading,
    list_item: @unordered_list,
    list_item: @ordered_list,
    blockquote: @blockquote,
    fence_marker: @fence_marker
  ]

  @enforce_keys [:work_item, :invariants, :acceptance_criteria, :non_goals, :dependencies, :follow_ups]
  defstruct [:work_item, :invariants, :acceptance_criteria, :non_goals, :dependencies, :follow_ups]

  @type field :: :work_item | :invariants | :acceptance_criteria | :non_goals | :dependencies | :follow_ups

  @type error ::
          :missing_scope_contract
          | {:duplicate_scope_contract}
          | {:missing_section, field()}
          | {:duplicate_section, field()}
          | {:unexpected_section, String.t()}
          | {:sections_out_of_order, [field()]}
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

  @typep normalized_item :: {:value, String.t()} | {:none, :standalone | :continued}
  @typep token_kind ::
           :blank
           | :text
           | :fenced
           | :thematic_break
           | :blockquote
           | :fence_marker
           | {:heading, 1..6, String.t()}
           | {:list_item, String.t(), String.t()}

  @typep line_token :: %{
           kind: token_kind(),
           value: String.t(),
           top_level?: boolean(),
           continuation?: boolean()
         }

  @spec parse_pr_body(String.t()) :: {:ok, t()} | {:error, [error()]}
  def parse_pr_body(pr_body) do
    case scope_contract_tokens(pr_body) do
      :missing ->
        {:error, [:missing_scope_contract]}

      {tokens, outer_errors} ->
        {sections, structural_errors} = collect_sections(tokens)
        {values, validation_errors} = validate_sections(sections)
        errors = outer_errors ++ structural_errors ++ validation_errors

        if errors == [] do
          {:ok, struct!(__MODULE__, values)}
        else
          {:error, errors}
        end
    end
  end

  defp scope_contract_tokens(pr_body) do
    tokens = tokenize(pr_body)
    outer_headings = Enum.count(tokens, &scope_contract_heading?/1)

    case Enum.find_index(tokens, &scope_contract_heading?/1) do
      nil ->
        :missing

      index ->
        errors = if outer_headings > 1, do: [{:duplicate_scope_contract}], else: []

        scope_tokens =
          tokens
          |> Enum.drop(index + 1)
          |> Enum.take_while(&(not level_four_heading_token?(&1)))

        {scope_tokens, errors}
    end
  end

  @spec collect_sections([line_token()]) :: {%{field() => [line_token()]}, [error()]}
  defp collect_sections(tokens) do
    {reversed_sections, reversed_errors, _current, reversed_fields} =
      Enum.reduce(tokens, {%{}, [], nil, []}, &collect_section_token/2)

    sections = Map.new(reversed_sections, fn {field, section_lines} -> {field, Enum.reverse(section_lines)} end)
    observed_fields = Enum.reverse(reversed_fields)
    errors = Enum.reverse(reversed_errors) ++ section_order_errors(observed_fields)

    {sections, errors}
  end

  defp collect_section_token(token, state) do
    case section_heading(token) do
      {:known, field} -> collect_known_section(field, state)
      {:unknown, heading} -> collect_unknown_section(heading, state)
      :content -> collect_section_content(token, state)
    end
  end

  defp collect_known_section(field, {sections, errors, _current, fields}) do
    next_fields = [field | fields]

    if Map.has_key?(sections, field) do
      {sections, [{:duplicate_section, field} | errors], :ignore, next_fields}
    else
      {Map.put(sections, field, []), errors, field, next_fields}
    end
  end

  defp collect_unknown_section(heading, {sections, errors, _current, fields}) do
    {sections, [{:unexpected_section, heading} | errors], :ignore, fields}
  end

  defp collect_section_content(token, {sections, errors, current, fields} = state) do
    if Map.has_key?(sections, current) do
      {Map.update!(sections, current, &[token | &1]), errors, current, fields}
    else
      state
    end
  end

  defp section_heading(%{kind: {:heading, 5, title}, top_level?: true}) when title != "" do
    case Enum.find(@fields, fn {_field, field_title} -> title == field_title end) do
      {field, _title} ->
        {:known, field}

      nil ->
        {:unknown, title}
    end
  end

  defp section_heading(_token), do: :content

  defp section_order_errors(observed_fields) do
    ranks = Enum.map(observed_fields, &Map.fetch!(@field_ranks, &1))

    if ranks == Enum.sort(ranks), do: [], else: [{:sections_out_of_order, observed_fields}]
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

  defp validate_work_item(tokens) do
    values = nonblank_tokens(tokens)

    cond do
      placeholder?(values) ->
        {"", [{:placeholder_comment, :work_item}]}

      values == [] ->
        {"", [{:empty_section, :work_item}]}

      length(values) == 1 ->
        validate_work_item_token(hd(values))

      true ->
        {"", [{:invalid_work_item, :multiple_values}]}
    end
  end

  defp validate_work_item_token(%{kind: :text, value: "None"}),
    do: {"", [{:none_not_allowed, :work_item}]}

  defp validate_work_item_token(%{kind: {:list_item, "-", "None"}}),
    do: {"", [{:none_not_allowed, :work_item}]}

  defp validate_work_item_token(%{kind: {:list_item, "-", ""}}),
    do: {"", [{:blank_bullet, :work_item}]}

  defp validate_work_item_token(%{kind: :text, value: value}), do: {value, []}

  defp validate_work_item_token(%{value: value}),
    do: {"", [{:malformed_bullet, :work_item, value}]}

  defp validate_list(field, tokens) do
    values = nonblank_tokens(tokens)

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

  @spec normalize_bullets(field(), [line_token()]) :: {[normalized_item()], [error()]}
  defp normalize_bullets(field, tokens) do
    {reversed_values, reversed_errors} = Enum.reduce(tokens, {[], []}, &normalize_bullet(field, &1, &2))

    {Enum.reverse(reversed_values), Enum.reverse(reversed_errors)}
  end

  defp normalize_bullet(field, %{kind: kind, continuation?: true, value: value}, state)
       when kind != :text do
    malformed_bullet(field, value, state)
  end

  defp normalize_bullet(_field, %{kind: :text, value: "None"}, {items, errors}) do
    {[{:none, :standalone} | items], errors}
  end

  defp normalize_bullet(field, %{kind: {:list_item, "-", ""}}, {items, errors}) do
    {items, [{:blank_bullet, field} | errors]}
  end

  defp normalize_bullet(_field, %{kind: {:list_item, "-", value}}, {items, errors}) do
    {[normalized_item(value) | items], errors}
  end

  defp normalize_bullet(field, %{kind: :text, continuation?: true, value: value}, state) do
    append_continuation(field, value, state)
  end

  defp normalize_bullet(field, %{value: value}, state), do: malformed_bullet(field, value, state)

  defp append_continuation(_field, value, {[{:value, previous} | items], errors}) do
    {[{:value, previous <> " " <> value} | items], errors}
  end

  defp append_continuation(field, value, {[{:none, _state} | items], errors}) do
    {[{:none, :continued} | items], [{:malformed_bullet, field, value} | errors]}
  end

  defp append_continuation(field, value, {[], errors}) do
    {[], [{:malformed_bullet, field, value} | errors]}
  end

  defp malformed_bullet(field, value, {values, errors}) do
    {values, [{:malformed_bullet, field, value} | errors]}
  end

  defp validate_normalized_list(field, [{:none, :standalone}]) when field in @optional_none_fields, do: {[], []}

  defp validate_normalized_list(:acceptance_criteria, items) do
    criterion_values = normalized_values(items)
    criterion_errors = acceptance_criterion_errors(criterion_values)

    if none_item?(items) do
      {[], [{:none_not_allowed, :acceptance_criteria} | criterion_errors]}
    else
      {criterion_values, criterion_errors}
    end
  end

  defp validate_normalized_list(field, items) do
    if none_item?(items) do
      {[], [{none_error(field), field}]}
    else
      {normalized_values(items), []}
    end
  end

  defp normalized_item("None"), do: {:none, :standalone}
  defp normalized_item(value), do: {:value, value}

  defp normalized_values(items), do: for({:value, value} <- items, do: value)
  defp none_item?(items), do: Enum.any?(items, &match?({:none, _state}, &1))

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

  defp nonblank_tokens(tokens), do: Enum.reject(tokens, &(&1.value == ""))
  defp placeholder?(tokens), do: Enum.any?(tokens, &String.contains?(&1.value, "<!--"))
  defp none_error(field) when field in @required_list_fields, do: :none_not_allowed
  defp none_error(_field), do: :none_must_be_explicit

  @spec tokenize(String.t()) :: [line_token()]
  defp tokenize(pr_body) do
    lines =
      pr_body
      |> String.replace("\r\n", "\n")
      |> String.split("\n")

    {tokens, _fence} = Enum.map_reduce(lines, nil, &tokenize_line/2)
    tokens
  end

  defp tokenize_line(line, nil) do
    case opening_fence(line) do
      {:ok, fence} -> {line_token(line, :fenced), fence}
      :none -> {unfenced_line_token(line), nil}
    end
  end

  defp tokenize_line(line, fence) do
    next_fence = if closing_fence?(line, fence), do: nil, else: fence
    {line_token(line, :fenced), next_fence}
  end

  defp unfenced_line_token(line) do
    token = line_token(line, :text)
    %{token | kind: markdown_structure(token.value)}
  end

  defp line_token(line, kind) do
    %{
      kind: kind,
      value: String.trim(line),
      top_level?: String.trim_leading(line) == line,
      continuation?: Regex.match?(@continuation_indent, line)
    }
  end

  defp markdown_structure(""), do: :blank

  defp markdown_structure(value) do
    @markdown_structures
    |> Enum.find_value(&match_markdown_structure(&1, value))
    |> build_token_kind()
  end

  defp match_markdown_structure({kind, pattern}, value) do
    case Regex.named_captures(pattern, value) do
      nil -> nil
      captures -> {kind, captures}
    end
  end

  defp build_token_kind(nil), do: :text
  defp build_token_kind({:thematic_break, _captures}), do: :thematic_break
  defp build_token_kind({:blockquote, _captures}), do: :blockquote
  defp build_token_kind({:fence_marker, _captures}), do: :fence_marker

  defp build_token_kind({:heading, %{"content" => content, "marker" => marker}}) do
    {:heading, String.length(marker), String.trim_trailing(content)}
  end

  defp build_token_kind({:list_item, %{"content" => content, "marker" => marker}}) do
    {:list_item, marker, String.trim(content)}
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

  defp scope_contract_heading?(%{kind: {:heading, 4, "Scope Contract"}, top_level?: true}), do: true
  defp scope_contract_heading?(_token), do: false

  defp acceptance_criterion_identifier(value) do
    case Regex.run(~r/^(AC-[1-9][0-9]*):\s+\S/, value) do
      [_, identifier] -> {:ok, identifier}
      nil -> :error
    end
  end

  defp level_four_heading_token?(%{kind: {:heading, 4, _title}, top_level?: true}), do: true
  defp level_four_heading_token?(_token), do: false
end
