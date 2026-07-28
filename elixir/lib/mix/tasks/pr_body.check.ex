defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  alias SymphonyElixir.ScopeContract

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @template_paths [
    ".github/pull_request_template.md",
    "../.github/pull_request_template.md"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        with {:ok, template_path, template} <- read_template(),
             {:ok, body} <- read_file(file_path),
             {:ok, headings} <- extract_template_headings(template, template_path),
             :ok <- lint_and_print(template_path, template, body, headings) do
          Mix.shell().info("PR body format OK")
        else
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  defp read_template do
    case Enum.find_value(@template_paths, &read_template_candidate/1) do
      {:ok, _path, _template} = result ->
        result

      nil ->
        joined_paths = Enum.join(@template_paths, ", ")
        {:error, "Unable to read PR template from any of: #{joined_paths}"}
    end
  end

  defp read_template_candidate(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, path, content}
      {:error, _reason} -> nil
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp extract_template_headings(template, template_path) do
    headings =
      Regex.scan(~r/^\#{4,6}\s+.+$/m, template)
      |> Enum.map(&hd/1)

    if headings == [] do
      {:error, "No markdown headings found in #{template_path}"}
    else
      {:ok, headings}
    end
  end

  defp lint_and_print(template_path, template, body, headings) do
    errors = lint(template, body, headings)

    if errors == [] do
      :ok
    else
      Enum.each(errors, fn err -> Mix.shell().error("ERROR: #{err}") end)

      {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
    end
  end

  defp lint(template, body, headings) do
    []
    |> check_required_headings(body, headings)
    |> check_order(body, headings)
    |> check_no_placeholders(body)
    |> check_sections_from_template(template, body, headings)
    |> check_scope_contract(body)
  end

  defp check_scope_contract(errors, body) do
    case ScopeContract.parse_pr_body(body) do
      {:ok, _contract} -> errors
      {:error, contract_errors} -> errors ++ Enum.map(contract_errors, &format_scope_contract_error/1)
    end
  end

  defp format_scope_contract_error(:missing_scope_contract), do: "Missing Scope Contract section."
  defp format_scope_contract_error({:duplicate_scope_contract}), do: "Duplicate Scope Contract section."

  defp format_scope_contract_error({:missing_section, field}),
    do: "Missing Scope Contract section: #{scope_contract_field_name(field)}"

  defp format_scope_contract_error({:duplicate_section, field}),
    do: "Duplicate Scope Contract section: #{scope_contract_field_name(field)}"

  defp format_scope_contract_error({:unexpected_section, heading}),
    do: "Unexpected Scope Contract section: #{heading}"

  defp format_scope_contract_error({:malformed_section_heading, heading}),
    do: "Malformed Scope Contract section heading: #{heading}"

  defp format_scope_contract_error({:sections_out_of_order, _observed_fields}),
    do: "Scope Contract sections are out of order."

  defp format_scope_contract_error({:placeholder_comment, field}),
    do: "Scope Contract #{scope_contract_field_name(field)} contains a placeholder comment"

  defp format_scope_contract_error({:blank_bullet, field}),
    do: "Scope Contract #{scope_contract_field_name(field)} contains a blank bullet"

  defp format_scope_contract_error({:none_not_allowed, field}),
    do: "Scope Contract #{scope_contract_field_name(field)} cannot be None"

  defp format_scope_contract_error({:none_must_be_explicit, field}),
    do: "Scope Contract #{scope_contract_field_name(field)} must use None by itself"

  defp format_scope_contract_error({:empty_section, field}),
    do: "Scope Contract #{scope_contract_field_name(field)} cannot be empty"

  defp format_scope_contract_error({:malformed_bullet, field, value}),
    do: "Scope Contract #{scope_contract_field_name(field)} has malformed bullet: #{value}"

  defp format_scope_contract_error({:malformed_acceptance_criterion, value}),
    do: "Scope Contract Acceptance Criteria has malformed criterion: #{value}"

  defp format_scope_contract_error({:duplicate_acceptance_criterion, identifier}),
    do: "Scope Contract Acceptance Criteria duplicates identifier: #{identifier}"

  defp format_scope_contract_error({:invalid_work_item, :multiple_values}),
    do: "Scope Contract Work Item must contain exactly one value"

  defp scope_contract_field_name(:work_item), do: "Work Item"
  defp scope_contract_field_name(:invariants), do: "Invariants"
  defp scope_contract_field_name(:acceptance_criteria), do: "Acceptance Criteria"
  defp scope_contract_field_name(:non_goals), do: "Non-Goals"
  defp scope_contract_field_name(:dependencies), do: "Dependencies"
  defp scope_contract_field_name(:follow_ups), do: "Follow-Ups"

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> heading_position(body, heading) == :nomatch end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body, headings) do
    positions =
      headings
      |> Enum.filter(&legacy_order_heading?/1)
      |> Enum.map(&heading_position(body, &1))
      |> Enum.reject(&(&1 == :nomatch))

    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp legacy_order_heading?(<<"#### ", _rest::binary>>), do: true
  defp legacy_order_heading?(_heading), do: false

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--") do
      errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."]
    else
      errors
    end
  end

  defp check_sections_from_template(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_heading_section(template, heading, headings)
      body_section = capture_heading_section(body, heading, headings)

      cond do
        is_nil(body_section) ->
          acc

        String.trim(body_section) == "" ->
          acc ++ ["Section cannot be empty: #{heading}"]

        true ->
          acc
          |> maybe_require_bullets(heading, template_section, body_section)
          |> maybe_require_checkboxes(heading, template_section, body_section)
      end
    end)
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not Regex.match?(~r/^- /m, body_section) do
      errors ++ ["Section must include at least one bullet item: #{heading}"]
    else
      errors
    end
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section) do
      errors ++ ["Section must include at least one checkbox item: #{heading}"]
    else
      errors
    end
  end

  defp heading_position(body, heading) do
    case exact_heading_match(body, heading) do
      {idx, _len} -> idx
      nil -> :nomatch
    end
  end

  defp capture_heading_section(doc, heading, headings) do
    with {heading_idx, heading_length} <- exact_heading_match(doc, heading),
         section_start <- heading_idx + heading_length,
         true <- section_start + 2 <= byte_size(doc),
         "\n\n" <- binary_part(doc, section_start, 2) do
      extract_section_content(doc, section_start + 2, heading, headings)
    else
      nil -> nil
      false -> ""
      _ -> nil
    end
  end

  defp extract_section_content(doc, content_start, heading, headings) do
    content = binary_part(doc, content_start, byte_size(doc) - content_start)

    case next_heading_offset(content, heading, headings) do
      nil -> content
      offset -> binary_part(content, 0, offset)
    end
  end

  defp next_heading_offset(content, heading, headings) do
    headings_after(heading, headings)
    |> Enum.map(&following_heading_match(content, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {idx, _} -> idx end)
    |> case do
      [] -> nil
      indexes -> Enum.min(indexes)
    end
  end

  defp headings_after(current_heading, headings) do
    headings
    |> Enum.filter(&(&1 != current_heading))
  end

  defp exact_heading_match(doc, heading) do
    pattern = ~r/^#{Regex.escape(heading)}(?:[ \t]+#+)?[ \t]*$/m

    case Regex.run(pattern, doc, return: :index, capture: :first) do
      [{idx, length}] -> {idx, length}
      nil -> nil
    end
  end

  defp following_heading_match(doc, heading) do
    pattern = ~r/\n#{Regex.escape(heading)}(?:[ \t]+#+)?[ \t]*$/m

    case Regex.run(pattern, doc, return: :index, capture: :first) do
      [{idx, length}] -> {idx, length}
      nil -> nil
    end
  end
end
