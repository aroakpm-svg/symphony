defmodule SymphonyElixir.FindingRouter do
  @moduledoc """
  Verifies the Central Brain finding-routing receipt envelope and turns its dispositions into
  bounded Symphony actions.

  This module does not recompute diff, scope, review, or classification policy. It only trusts one
  exact completed check run from the fixed Central readiness workflow and validates the receipt's
  immutable PR envelope.
  """

  @check_name "Work Routing / Readiness"
  @workflow_path ".github/workflows/work-routing-readiness.yml"
  @publisher_app_id 15_368
  @trusted_follow_up_actor_node_id "U_kgDOEDjIhA"
  @receipt_schema_v2 "aroak.work-routing-readiness.v2"
  @receipt_schema_v3 "aroak.work-routing-readiness.v3"
  @receipt_marker_v2 "<!-- aroak-readiness-receipt:v2\n"
  @receipt_marker_v3 "<!-- aroak-readiness-receipt:v3\n"
  @follow_up_marker_token "<!-- symphony-follow-up:v1"
  @follow_up_marker_start "#{@follow_up_marker_token}\n"
  @marker_end "\n-->"
  @full_sha ~r/\A[0-9a-f]{40}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @type action ::
          {:comment_then_resolve, map()}
          | {:resolve, map()}

  @type plan ::
          {:hold, atom()}
          | {:rework, [map()]}
          | {:settle, [action()]}
          | :pass

  @spec check_name() :: String.t()
  def check_name, do: @check_name

  @spec workflow_path() :: String.t()
  def workflow_path, do: @workflow_path

  @spec publisher_app_id() :: pos_integer()
  def publisher_app_id, do: @publisher_app_id

  @spec trusted_follow_up_actor_node_id() :: String.t()
  def trusted_follow_up_actor_node_id, do: @trusted_follow_up_actor_node_id

  @spec select_latest_check_run([map()], String.t()) :: {:ok, map()} | {:error, term()}
  def select_latest_check_run(check_runs, head_sha)
      when is_list(check_runs) and is_binary(head_sha) do
    with true <- Enum.all?(check_runs, &is_map/1),
         candidates <- Enum.filter(check_runs, &(&1["name"] == @check_name)),
         true <- Regex.match?(@full_sha, head_sha),
         [_ | _] <- candidates,
         {:ok, latest} <- unique_latest(candidates),
         true <- latest["status"] == "completed",
         true <- latest["head_sha"] == head_sha,
         true <- nested_value(latest, "app", "id") == @publisher_app_id do
      {:ok, latest}
    else
      false -> {:error, :readiness_check_envelope_invalid}
      [] -> {:error, :readiness_check_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def select_latest_check_run(_check_runs, _head_sha),
    do: {:error, :readiness_check_evidence_invalid}

  @spec verify_receipt(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def verify_receipt(check_run, workflow_run, identity)
      when is_map(check_run) and is_map(workflow_run) and is_map(identity) do
    with :ok <- verify_check_and_workflow(check_run, workflow_run, identity),
         {:ok, receipt} <- parse_receipt(nested_value(check_run, "output", "text")),
         :ok <- verify_receipt_shape(receipt, identity),
         :ok <- verify_check_outcome(check_run, receipt) do
      {:ok, receipt}
    end
  end

  def verify_receipt(_check_run, _workflow_run, _identity),
    do: {:error, :readiness_receipt_envelope_invalid}

  @spec plan(map(), [map()], [map()]) :: plan()
  def plan(receipt, threads, issue_comments)
      when is_map(receipt) and is_list(threads) and is_list(issue_comments) do
    dispositions = receipt["findingDispositions"]

    with true <- is_list(dispositions),
         true <- valid_dispositions?(dispositions),
         {:ok, indexed_threads} <- index_threads(threads),
         true <- unique_ids?(dispositions, "findingId"),
         true <- complete_thread_bindings?(dispositions, indexed_threads) do
      rework = rework_items(dispositions, indexed_threads)

      cond do
        Enum.any?(dispositions, &(&1["disposition"] == "blocked_unverified")) ->
          {:hold, :finding_ownership_unverified}

        rework != [] ->
          {:rework, rework}

        true ->
          settle_plan(receipt, dispositions, indexed_threads, issue_comments)
      end
    else
      _ -> {:hold, :finding_router_evidence_invalid}
    end
  end

  def plan(_receipt, _threads, _issue_comments),
    do: {:hold, :finding_router_evidence_invalid}

  @spec follow_up_comment(map(), String.t(), String.t()) :: String.t()
  def follow_up_comment(disposition, source_head_sha, receipt_digest) do
    follow_up = disposition["followUp"]

    marker = %{
      "findingId" => disposition["findingId"],
      "sourceHeadSha" => source_head_sha,
      "receiptDigest" => receipt_digest
    }

    """
    ## 建議另開票處理

    - 為什麼要另開票：#{follow_up["whySeparate"]}
    - 要處理什麼：#{follow_up["work"]}
    - 不處理的影響：#{follow_up["risk"]}
    - 處理完成的好處：#{follow_up["benefit"]}

    這則留言只留下後續去向，不授權在目前 PR 擴大實作範圍。

    #{@follow_up_marker_start}#{Jason.encode!(marker)}#{@marker_end}
    """
  end

  @spec trusted_follow_up_comment?(map(), String.t(), String.t(), String.t()) :: boolean()
  def trusted_follow_up_comment?(comment, finding_id, source_head_sha, receipt_digest)
      when is_map(comment) do
    with true <- nested_value(comment, "user", "node_id") == @trusted_follow_up_actor_node_id,
         {:ok, marker} <- parse_follow_up_marker(comment["body"]),
         true <- exact_keys?(marker, ["findingId", "sourceHeadSha", "receiptDigest"]) do
      marker == %{
        "findingId" => finding_id,
        "sourceHeadSha" => source_head_sha,
        "receiptDigest" => receipt_digest
      }
    else
      _ -> false
    end
  end

  def trusted_follow_up_comment?(_comment, _finding_id, _source_head_sha, _receipt_digest),
    do: false

  @spec trusted_follow_up_response?(map(), String.t()) :: boolean()
  def trusted_follow_up_response?(response, expected_body)
      when is_map(response) and is_binary(expected_body) do
    with true <- response["body"] == expected_body,
         {:ok, expected_marker} <- parse_follow_up_marker(expected_body),
         true <- exact_keys?(expected_marker, ["findingId", "sourceHeadSha", "receiptDigest"]) do
      trusted_follow_up_comment?(
        response,
        expected_marker["findingId"],
        expected_marker["sourceHeadSha"],
        expected_marker["receiptDigest"]
      )
    else
      _ -> false
    end
  end

  def trusted_follow_up_response?(_response, _expected_body), do: false

  defp unique_latest(candidates) do
    case parse_candidate_times(candidates) do
      {:ok, timestamped} -> select_unique_latest(timestamped)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_unique_latest(timestamped) do
    latest_time =
      timestamped
      |> Enum.map(fn {_candidate, timestamp} -> timestamp end)
      |> Enum.max(DateTime)

    case Enum.filter(timestamped, &same_timestamp?(&1, latest_time)) do
      [{latest, _timestamp}] -> {:ok, latest}
      _ -> {:error, :readiness_check_latest_ambiguous}
    end
  end

  defp same_timestamp?({_candidate, timestamp}, expected),
    do: DateTime.compare(timestamp, expected) == :eq

  defp parse_candidate_times(candidates), do: parse_candidate_times(candidates, [])

  defp parse_candidate_times([], parsed), do: {:ok, parsed}

  defp parse_candidate_times([%{"created_at" => value} = candidate | rest], parsed)
       when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} ->
        parse_candidate_times(rest, [{candidate, timestamp} | parsed])

      _ ->
        {:error, :readiness_check_time_invalid}
    end
  end

  defp parse_candidate_times([_candidate | _rest], _parsed),
    do: {:error, :readiness_check_time_missing}

  defp verify_check_and_workflow(check_run, workflow_run, identity) do
    expected_repository = identity[:repository]
    expected_head = identity[:head_sha]
    expected_base = identity[:base_sha]
    check_suite_id = nested_value(check_run, "check_suite", "id")

    valid =
      Enum.all?([
        check_run["name"] == @check_name,
        check_run["status"] == "completed",
        check_run["head_sha"] == expected_head,
        nested_value(check_run, "app", "id") == @publisher_app_id,
        is_integer(check_suite_id),
        workflow_run["status"] == "completed",
        workflow_run["path"] == @workflow_path,
        workflow_run["event"] == "pull_request_target",
        workflow_run["head_sha"] == expected_base,
        workflow_run["check_suite_id"] == check_suite_id,
        nested_value(workflow_run, "repository", "full_name") == expected_repository
      ])

    if valid, do: :ok, else: {:error, :readiness_workflow_envelope_invalid}
  end

  defp parse_receipt(body) do
    candidates =
      [
        {@receipt_schema_v2, @receipt_marker_v2},
        {@receipt_schema_v3, @receipt_marker_v3}
      ]
      |> Enum.flat_map(fn {schema, marker} ->
        case parse_single_marker(body, marker) do
          {:ok, %{"schemaVersion" => ^schema} = receipt} -> [receipt]
          _ -> []
        end
      end)

    case candidates do
      [receipt] -> {:ok, receipt}
      _ -> {:error, :readiness_receipt_marker_invalid}
    end
  end

  defp verify_receipt_shape(receipt, identity) do
    common_top_level = [
      "baseSha",
      "blockers",
      "checkSet",
      "decision",
      "evidence",
      "findingDispositions",
      "headSha",
      "pullRequestNumber",
      "receiptDigest",
      "repository",
      "schemaVersion",
      "snapshotDigest"
    ]

    {exact_top_level, merge_decision_valid} = receipt_schema_contract(receipt, common_top_level)
    evidence = receipt["evidence"]

    valid =
      is_map(evidence) and
        Enum.all?([
          exact_keys?(receipt, exact_top_level),
          receipt["schemaVersion"] in [@receipt_schema_v2, @receipt_schema_v3],
          merge_decision_valid,
          receipt["repository"] == identity[:repository],
          receipt["pullRequestNumber"] == identity[:pull_request_number],
          receipt["baseSha"] == identity[:base_sha],
          receipt["headSha"] == identity[:head_sha],
          sha256?(receipt["snapshotDigest"]),
          sha256?(receipt["receiptDigest"]),
          receipt["decision"] in ["blocked", "ready"],
          receipt["checkSet"] in ["full", "ui_fast"],
          string_list?(receipt["blockers"]),
          evidence["policySha"] == identity[:base_sha],
          evidence["baseSha"] == identity[:base_sha],
          evidence["headSha"] == identity[:head_sha],
          valid_dispositions?(receipt["findingDispositions"])
        ])

    if valid, do: :ok, else: {:error, :readiness_receipt_shape_invalid}
  end

  defp receipt_schema_contract(%{"schemaVersion" => @receipt_schema_v2}, common_top_level),
    do: {common_top_level, true}

  defp receipt_schema_contract(%{"schemaVersion" => @receipt_schema_v3} = receipt, common_top_level) do
    valid =
      receipt["mergeDecision"] in ["blocked", "human_required", "auto_ready"] and
        receipt["decision"] == "blocked" == (receipt["mergeDecision"] == "blocked")

    {common_top_level ++ ["mergeDecision"], valid}
  end

  defp verify_check_outcome(check_run, receipt) do
    expected = if receipt["decision"] == "ready", do: "success", else: "failure"
    if check_run["conclusion"] == expected, do: :ok, else: {:error, :readiness_check_outcome_mismatch}
  end

  defp valid_dispositions?(dispositions) when is_list(dispositions) do
    Enum.all?(dispositions, &is_map/1) and
      unique_ids?(dispositions, "findingId") and
      Enum.all?(dispositions, &valid_disposition?/1)
  end

  defp valid_dispositions?(_dispositions), do: false

  defp valid_disposition?(%{"disposition" => disposition} = value)
       when disposition in ["blocked_unverified", "fix_in_current_pr"] do
    valid_disposition_fields?(value, common_disposition_keys())
  end

  defp valid_disposition?(%{"disposition" => "remove_out_of_scope_change"} = value) do
    follow_up_keys = if Map.has_key?(value, "followUp"), do: ["followUp"], else: []

    valid_disposition_fields?(
      value,
      common_disposition_keys() ++ ["removalStatus"] ++ follow_up_keys
    ) and value["removalStatus"] in ["pending", "verified"]
  end

  defp valid_disposition?(%{"disposition" => "suggest_follow_up"} = value) do
    valid_disposition_fields?(value, common_disposition_keys() ++ ["followUp"])
  end

  defp valid_disposition?(_value), do: false

  defp valid_disposition_fields?(value, keys) do
    Enum.all?([
      exact_keys?(value, keys),
      opaque_id?(value["findingId"]),
      is_nil(value["findingCommentId"]) or opaque_id?(value["findingCommentId"]),
      is_nil(value["findingCommentDigest"]) or sha256?(value["findingCommentDigest"]),
      sha256?(value["evidenceDigest"]),
      not Map.has_key?(value, "followUp") or valid_follow_up?(value["followUp"])
    ])
  end

  defp common_disposition_keys,
    do: ["disposition", "evidenceDigest", "findingCommentDigest", "findingCommentId", "findingId"]

  defp valid_follow_up?(value) when is_map(value) do
    exact_keys?(value, ["benefit", "risk", "whySeparate", "work"]) and
      Enum.all?(Map.values(value), &substantive_text?/1)
  end

  defp valid_follow_up?(_value), do: false

  defp index_threads(threads) do
    if Enum.all?(threads, fn thread ->
         is_map(thread) and
           opaque_id?(thread[:finding_id]) and
           opaque_id?(thread[:finding_comment_id]) and
           sha256?(thread[:finding_comment_digest]) and
           is_boolean(thread[:resolved])
       end) and
         unique_ids?(threads, :finding_id) do
      {:ok, Map.new(threads, &{&1.finding_id, &1})}
    else
      {:error, :review_thread_identity_invalid}
    end
  end

  defp complete_thread_bindings?(dispositions, indexed_threads) do
    disposition_ids = MapSet.new(dispositions, & &1["findingId"])

    unresolved_ids =
      indexed_threads
      |> Map.values()
      |> Enum.reject(& &1.resolved)
      |> MapSet.new(& &1.finding_id)

    MapSet.subset?(unresolved_ids, disposition_ids) and
      Enum.all?(dispositions, fn disposition ->
        case indexed_threads[disposition["findingId"]] do
          nil ->
            false

          thread ->
            disposition["findingCommentId"] == thread.finding_comment_id and
              disposition["findingCommentDigest"] == thread.finding_comment_digest
        end
      end)
  end

  defp rework_items(dispositions, indexed_threads) do
    dispositions
    |> Enum.flat_map(fn disposition ->
      case {disposition["disposition"], disposition["removalStatus"]} do
        {"fix_in_current_pr", _} ->
          [Map.put(indexed_threads[disposition["findingId"]], :router_action, :fix_in_current_pr)]

        {"remove_out_of_scope_change", "pending"} ->
          [Map.put(indexed_threads[disposition["findingId"]], :router_action, :remove_out_of_scope_change)]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn item ->
      {item.finding_id, item.finding_comment_id, item.router_action}
    end)
  end

  defp settle_plan(receipt, dispositions, indexed_threads, issue_comments) do
    Enum.reduce_while(dispositions, {:ok, []}, fn disposition, {:ok, actions} ->
      thread = indexed_threads[disposition["findingId"]]

      case settlement_action(receipt, disposition, thread, issue_comments) do
        :none -> {:cont, {:ok, actions}}
        {:ok, action} -> {:cont, {:ok, [action | actions]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> :pass
      {:ok, actions} -> {:settle, Enum.reverse(actions)}
      {:error, reason} -> {:hold, reason}
    end
  end

  defp settlement_action(receipt, disposition, thread, issue_comments) do
    case disposition["disposition"] do
      "remove_out_of_scope_change" ->
        if disposition["removalStatus"] == "verified" do
          follow_up_settlement(receipt, disposition, thread, issue_comments)
        else
          {:error, :finding_removal_unverified}
        end

      "suggest_follow_up" ->
        follow_up_settlement(receipt, disposition, thread, issue_comments)
    end
  end

  defp follow_up_settlement(receipt, disposition, %{resolved: resolved}, issue_comments) do
    follow_up = disposition["followUp"]

    cond do
      is_nil(follow_up) and resolved ->
        :none

      is_nil(follow_up) ->
        {:ok, {:resolve, disposition}}

      trusted_marker_exists?(issue_comments, disposition, receipt) and resolved ->
        :none

      trusted_marker_exists?(issue_comments, disposition, receipt) ->
        {:ok, {:resolve, disposition}}

      resolved ->
        {:error, :follow_up_marker_missing_before_resolve}

      true ->
        {:ok, {:comment_then_resolve, disposition}}
    end
  end

  defp trusted_marker_exists?(issue_comments, disposition, receipt) do
    Enum.any?(issue_comments, fn comment ->
      trusted_follow_up_comment?(
        comment,
        disposition["findingId"],
        receipt["headSha"],
        receipt["receiptDigest"]
      )
    end)
  end

  defp parse_single_marker(body, prefix) when is_binary(body) do
    with [_before, rest] <- String.split(body, prefix),
         [json, _after_marker] when json != "" <- String.split(rest, @marker_end),
         false <- String.contains?(json, "\n"),
         {:ok, value} <- Jason.decode(json) do
      {:ok, value}
    else
      true -> {:error, :marker_json_invalid}
      {:error, _reason} -> {:error, :marker_json_invalid}
      _ -> {:error, :marker_ambiguous}
    end
  end

  defp parse_single_marker(_body, _prefix), do: {:error, :marker_missing}

  defp parse_follow_up_marker(body) when is_binary(body) do
    with 2 <- body |> String.split(@follow_up_marker_token) |> length(),
         true <- canonical_follow_up_boundary?(body),
         {:ok, marker} <- parse_single_marker(body, @follow_up_marker_start) do
      {:ok, marker}
    else
      _ -> {:error, :marker_ambiguous}
    end
  end

  defp parse_follow_up_marker(_body), do: {:error, :marker_missing}

  defp canonical_follow_up_boundary?(body) do
    case :binary.match(body, @follow_up_marker_token) do
      {0, _length} -> true
      {index, _length} when index >= 2 -> binary_part(body, index - 2, 2) == "\n\n"
      _ -> false
    end
  end

  defp exact_keys?(map, expected) when is_map(map),
    do: map |> Map.keys() |> Enum.sort() == Enum.sort(expected)

  defp exact_keys?(_map, _expected), do: false

  defp unique_ids?(values, key) when is_list(values) do
    ids = Enum.map(values, & &1[key])
    Enum.all?(ids, &opaque_id?/1) and MapSet.size(MapSet.new(ids)) == length(ids)
  end

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &substantive_text?/1)
  defp string_list?(_values), do: false

  defp opaque_id?(value), do: substantive_text?(value)

  defp sha256?(value) when is_binary(value), do: Regex.match?(@sha256, value)
  defp sha256?(_value), do: false

  defp substantive_text?(value) when is_binary(value),
    do: value == String.trim(value) and value != "" and not String.match?(value, ~r/[\x00-\x1f\x7f]/)

  defp substantive_text?(_value), do: false

  defp nested_value(value, parent, child) when is_map(value) do
    case value[parent] do
      nested when is_map(nested) -> nested[child]
      _ -> nil
    end
  end
end
