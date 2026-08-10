defmodule SymphonyElixir.FindingDisposition do
  @moduledoc """
  Pure Design 2 contract for identifying, classifying, and ordering review findings.

  This module only consumes normalized provider facts. It deliberately has no
  GitHub, Linear, claim, ledger, persistence, or callback dependency.
  """

  @type disposition :: :fix_in_current_pr | :follow_up_required | :blocked_unverified
  @type effect_type ::
          :github_pr_update
          | :linear_issue_create
          | :github_comment
          | :github_review_thread_resolve

  @type finding_key :: %{
          repository: String.t(),
          pull_request_number: pos_integer(),
          source_head_sha: String.t(),
          review_thread_id: String.t(),
          selected_review_comment_id: String.t(),
          body_sha256: String.t(),
          digest: String.t()
        }

  @type finding_lineage_key :: %{
          repository: String.t(),
          pull_request_number: pos_integer(),
          review_thread_id: String.t(),
          digest: String.t()
        }

  @type decision :: %{
          disposition: disposition(),
          finding_key: finding_key() | nil,
          finding_key_digest: String.t(),
          finding_lineage_key: finding_lineage_key() | nil,
          facts: map()
        }

  @type plan :: %{
          decisions: [decision()],
          fix_decisions: [decision()],
          follow_up_decisions: [decision()],
          blocked_decisions: [decision()],
          merge_ready_blocked?: boolean(),
          preflight: map()
        }

  @type effect_intent :: map()
  @type managed_publish_identity :: map()

  @spec build_finding_key(map()) :: {:ok, finding_key()} | {:error, term()}
  def build_finding_key(input) when is_map(input) do
    with {:ok, repository} <- required_string(input, :repository),
         {:ok, pull_request_number} <- required_positive_integer(input, :pull_request_number),
         {:ok, source_head_sha} <- required_sha(input, :source_head_sha),
         {:ok, review_thread_id} <- required_string(input, :review_thread_id),
         {:ok, selected_review_comment_id} <- required_string(input, :selected_review_comment_id),
         {:ok, body} <- required_binary(input, :body) do
      body_sha256 = sha256(body)

      ordered_identity =
        {repository, pull_request_number, source_head_sha, review_thread_id, selected_review_comment_id, body_sha256}

      {:ok,
       %{
         repository: repository,
         pull_request_number: pull_request_number,
         source_head_sha: source_head_sha,
         review_thread_id: review_thread_id,
         selected_review_comment_id: selected_review_comment_id,
         body_sha256: body_sha256,
         digest: digest(:symphony_finding_identity_v1, ordered_identity)
       }}
    end
  end

  def build_finding_key(_input), do: {:error, :invalid_finding_key_input}

  @spec build_lineage_key(map()) :: {:ok, finding_lineage_key()} | {:error, term()}
  def build_lineage_key(input) when is_map(input) do
    with {:ok, repository} <- required_string(input, :repository),
         {:ok, pull_request_number} <- required_positive_integer(input, :pull_request_number),
         {:ok, review_thread_id} <- required_string(input, :review_thread_id) do
      identity = {repository, pull_request_number, review_thread_id}

      {:ok,
       %{
         repository: repository,
         pull_request_number: pull_request_number,
         review_thread_id: review_thread_id,
         digest: digest(:symphony_finding_lineage_v1, identity)
       }}
    end
  end

  def build_lineage_key(_input), do: {:error, :invalid_finding_lineage_input}

  @spec select_review_comment(map(), map()) ::
          {:ok, map()} | :no_fresh_evidence | {:error, term()}
  def select_review_comment(thread, options) when is_map(thread) and is_map(options) do
    with {:ok, comments} <- comments_for(thread),
         {:ok, ordered_comments} <- provider_order(comments),
         {:ok, candidates} <- trusted_candidates(ordered_comments) do
      resolved? = value(thread, :resolved?) == true

      if resolved? do
        select_resolved_comment(thread, options, candidates)
      else
        select_unresolved_comment(candidates)
      end
    end
  end

  def select_review_comment(_thread, _options), do: {:error, :invalid_review_thread}

  @spec classify(map(), map()) :: {:ok, decision()} | {:error, term()}
  def classify(facts, _preflight) when is_map(facts) do
    {finding_key, finding_lineage_key, finding_key_digest} = identity_for(facts)
    disposition = classify_disposition(facts)

    {:ok,
     %{
       disposition: disposition,
       finding_key: finding_key,
       finding_key_digest: finding_key_digest,
       finding_lineage_key: finding_lineage_key,
       facts: facts
     }}
  end

  def classify(_facts, _preflight), do: {:error, :invalid_finding_facts}

  @spec classify_all([map()], map()) ::
          {:ok, plan()} | {:error, {:global_blocker, term()}}
  def classify_all(findings, preflight) when is_list(findings) and is_map(preflight) do
    case global_preflight_blocker(preflight) do
      nil ->
        decisions = Enum.map(findings, &classify!(&1, preflight)) |> sort_decisions()
        fix_decisions = Enum.filter(decisions, &(&1.disposition == :fix_in_current_pr))
        follow_up_decisions = Enum.filter(decisions, &(&1.disposition == :follow_up_required))
        blocked_decisions = Enum.filter(decisions, &(&1.disposition == :blocked_unverified))

        {:ok,
         %{
           decisions: decisions,
           fix_decisions: fix_decisions,
           follow_up_decisions: follow_up_decisions,
           blocked_decisions: blocked_decisions,
           merge_ready_blocked?: blocked_decisions != [],
           preflight: preflight
         }}

      blocker ->
        {:error, {:global_blocker, blocker}}
    end
  end

  def classify_all(_findings, _preflight), do: {:error, {:global_blocker, :invalid_preflight}}

  @spec sort_decisions([decision()]) :: [decision()]
  def sort_decisions(decisions) when is_list(decisions) do
    Enum.sort_by(decisions, &Map.get(&1, :finding_key_digest, ""))
  end

  @spec head_guard(map(), String.t()) :: :ok | {:error, term()}
  def head_guard(plan, current_head_sha) when is_map(plan) and is_binary(current_head_sha) do
    with :ok <- validate_sha(current_head_sha, :current_head_sha),
         {:ok, evaluated_head_sha} <- fetch_required(plan, :evaluated_head_sha),
         :ok <- validate_sha(evaluated_head_sha, :evaluated_head_sha),
         :ok <- source_revalidation_guard(plan) do
      current_head_guard(evaluated_head_sha, current_head_sha)
    end
  end

  def head_guard(_plan, _current_head_sha), do: {:error, :invalid_head_guard_input}

  @spec operation_id(effect_type(), map()) :: {:ok, String.t()} | {:error, term()}
  def operation_id(effect_type, input) when is_map(input) do
    with :ok <- validate_effect_type(effect_type),
         {:ok, logical_identity} <- logical_operation_identity(effect_type, input) do
      {:ok, digest({:symphony_operation_identity_v1, effect_type}, logical_identity)}
    end
  end

  def operation_id(effect_type, _input), do: {:error, {:invalid_effect_type_or_input, effect_type}}

  @spec request_fingerprint(effect_intent()) :: {:ok, String.t()} | {:error, term()}
  def request_fingerprint(intent) when is_map(intent) do
    required = [
      :disposition,
      :finding_key,
      :finding_lineage_key,
      :evaluated_head_sha,
      :policy_version,
      :target,
      :payload,
      :resulting_tree_or_commit,
      :expected_transition
    ]

    with :ok <- validate_fingerprint_fields(intent, required),
         :ok <- validate_disposition(value(intent, :disposition)),
         :ok <- validate_sha(value(intent, :evaluated_head_sha), :evaluated_head_sha) do
      encoded = :erlang.term_to_binary({:symphony_request_fingerprint_v1, intent}, [:deterministic])

      {:ok, "symphony_request_fingerprint_v1:" <> Base.url_encode64(encoded, padding: false)}
    end
  end

  def request_fingerprint(_intent), do: {:error, :invalid_request_fingerprint_input}

  @spec decode_request_fingerprint(String.t()) :: {:ok, effect_intent()} | {:error, term()}
  def decode_request_fingerprint(fingerprint) when is_binary(fingerprint) do
    case String.split(fingerprint, ":", parts: 2) do
      ["symphony_request_fingerprint_v1", encoded] ->
        with {:ok, binary} <- Base.url_decode64(encoded, padding: false),
             {:ok, intent} <- decode_term(binary),
             {:ok, ^intent} <- validate_decoded_fingerprint(intent) do
          {:ok, intent}
        end

      [version, _encoded] ->
        {:error, {:unknown_request_fingerprint_version, version}}

      _ ->
        {:error, :invalid_request_fingerprint}
    end
  end

  def decode_request_fingerprint(_fingerprint), do: {:error, :invalid_request_fingerprint}

  @spec execution_steps(plan()) :: [term()]
  def execution_steps(plan) when is_map(plan) do
    decisions = Map.get(plan, :decisions, [])
    follow_up_decisions = Map.get(plan, :follow_up_decisions, filter_disposition(decisions, :follow_up_required))
    fix_decisions = Map.get(plan, :fix_decisions, filter_disposition(decisions, :fix_in_current_pr))
    blocked_decisions = Map.get(plan, :blocked_decisions, filter_disposition(decisions, :blocked_unverified))

    [
      :reconcile,
      {:settle_follow_up, follow_up_decisions},
      :refetch,
      :recompute_remaining,
      {:build_patch, fix_decisions},
      :validate_complete_batch,
      {:publish_one_head_transition, fix_decisions},
      :readback_and_request_exact_head_review,
      {:settle_fix_and_blocked, fix_decisions ++ blocked_decisions}
    ]
  end

  def execution_steps(_plan), do: []

  @spec reconcile_locks([map()]) ::
          {:ok, map()} | {:error, {:global_blocker, term()}}
  def reconcile_locks(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{locks: %{}}}, fn entry, {:ok, state} ->
      case reconcile_lock_entry(entry, state) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, {:global_blocker, reason}}}
      end
    end)
  end

  def reconcile_locks(_entries), do: {:error, {:global_blocker, :invalid_lock_entries}}

  defp classify!(facts, preflight) do
    {:ok, decision} = classify(facts, preflight)
    decision
  end

  defp classify_disposition(facts) do
    cond do
      fix_facts?(facts) -> :fix_in_current_pr
      follow_up_facts?(facts) -> :follow_up_required
      true -> :blocked_unverified
    end
  end

  defp fix_facts?(facts) do
    value(facts, :introduced_by_pr?) == true and
      value(facts, :still_applies?) == true and
      value(facts, :in_scope?) == true and
      value(facts, :root_cause_bounded?) == true and
      value(facts, :requires_new_decision?) == false
  end

  defp follow_up_facts?(facts) do
    value(facts, :safe_follow_up?) == true and
      value(facts, :in_scope?) == false and
      non_empty_string?(value(facts, :follow_up_destination)) and
      value(facts, :requires_new_decision?) == false
  end

  defp identity_for(facts) do
    case value(facts, :finding_key) do
      key when is_map(key) ->
        case Map.get(key, :digest) do
          digest when is_binary(digest) -> {key, lineage_from_key(key), digest}
          _ -> identity_from_facts(facts)
        end

      _ ->
        identity_from_facts(facts)
    end
  end

  defp identity_from_facts(facts) do
    case build_finding_key(facts) do
      {:ok, key} -> {key, lineage_from_key(key), key.digest}
      {:error, _reason} -> {nil, nil, fallback_digest(facts)}
    end
  end

  defp lineage_from_key(key) do
    case build_lineage_key(key) do
      {:ok, lineage} -> lineage
      {:error, _reason} -> nil
    end
  end

  defp fallback_digest(facts), do: digest(:symphony_blocked_finding_v1, :erlang.term_to_binary(facts, [:deterministic]))

  defp comments_for(thread) do
    case value(thread, :comments) do
      comments when is_list(comments) -> {:ok, comments}
      _ -> {:error, :invalid_review_comments}
    end
  end

  defp provider_order(comments) do
    comments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {comment, index}, {:ok, acc} ->
      connection_index = value(comment, :connection_index)

      cond do
        not is_map(comment) ->
          {:halt, {:error, :invalid_review_comment}}

        is_nil(connection_index) ->
          {:cont, {:ok, [{index, comment} | acc]}}

        is_integer(connection_index) and connection_index >= 0 ->
          {:cont, {:ok, [{connection_index, comment} | acc]}}

        true ->
          {:halt, {:error, :invalid_connection_order}}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, ordered |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      error -> error
    end
  end

  defp trusted_candidates(comments) do
    Enum.reduce_while(comments, {:ok, []}, fn comment, {:ok, candidates} ->
      case normalize_trusted_comment(comment) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | candidates]}}
        :skip -> {:cont, {:ok, candidates}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp normalize_trusted_comment(comment) do
    if value(comment, :trusted_review_source?) == true and
         value(comment, :managed_agent_reply?) != true and
         value(comment, :settlement_marker?) != true do
      with {:ok, id} <- required_string(comment, :id),
           {:ok, body} <- required_binary(comment, :body) do
        {:ok, Map.put(Map.put(comment, :id, id), :body_sha256, sha256(body))}
      end
    else
      :skip
    end
  end

  defp select_unresolved_comment([]), do: :no_fresh_evidence
  defp select_unresolved_comment(candidates), do: {:ok, List.last(candidates)}

  defp select_resolved_comment(thread, options, candidates) do
    thread_id = value(thread, :review_thread_id) || value(thread, :id)
    settled = value(options, :settled)

    cond do
      not non_empty_string?(thread_id) or not is_map(settled) ->
        {:error, :resolved_thread_settlement_unverified}

      not Map.has_key?(settled, thread_id) ->
        {:error, :resolved_thread_settlement_unverified}

      candidates == [] ->
        :no_fresh_evidence

      true ->
        settlement = Map.get(settled, thread_id)

        if settlement_matches?(List.last(candidates), settlement) do
          :no_fresh_evidence
        else
          {:ok, List.last(candidates)}
        end
    end
  end

  defp settlement_matches?(comment, settlement) when is_map(comment) and is_map(settlement) do
    value(comment, :id) == value(settlement, :comment_id) and
      value(comment, :body_sha256) == value(settlement, :body_sha256)
  end

  defp settlement_matches?(_comment, _settlement), do: false

  defp logical_operation_identity(:github_pr_update, input) do
    required_identity(input, [
      :repository,
      :pull_request_number,
      :evaluated_head_sha,
      :finding_set_digest,
      :authorization_identity
    ])
  end

  defp logical_operation_identity(:linear_issue_create, input) do
    required_identity(input, [
      :repository,
      :pull_request_number,
      :finding_lineage_key,
      :destination,
      :effect_type
    ])
  end

  defp logical_operation_identity(:github_comment, input) do
    with {:ok, _base_identity} <- required_identity(input, [:repository, :pull_request_number, :review_thread_id]),
         {:ok, finding_identity} <- required_finding_identity(input),
         {:ok, message_kind} <- required_present(input, :message_kind),
         {:ok, effect_type} <- required_present(input, :effect_type) do
      identity = {review_identity(input), finding_identity, message_kind, effect_type}

      {:ok, identity}
    end
  end

  defp logical_operation_identity(:github_review_thread_resolve, input) do
    with {:ok, _base_identity} <- required_identity(input, [:repository, :pull_request_number, :review_thread_id]),
         {:ok, lineage} <- required_present(input, :finding_lineage_key),
         {:ok, effect_type} <- required_present(input, :effect_type) do
      identity = {review_identity(input), lineage, effect_type}

      {:ok, identity}
    end
  end

  defp required_finding_identity(input) do
    cond do
      present?(input, :finding_key) -> required_present(input, :finding_key)
      present?(input, :finding_lineage_key) -> required_present(input, :finding_lineage_key)
      true -> {:error, {:missing_field, :finding_key_or_lineage_key}}
    end
  end

  defp review_identity(input),
    do: {value(input, :repository), value(input, :pull_request_number), value(input, :review_thread_id)}

  defp required_identity(input, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case required_present(input, field) do
        {:ok, _value} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.map(fields, &value(input, &1))}
      error -> error
    end
  end

  defp validate_effect_type(effect_type)
       when effect_type in [
              :github_pr_update,
              :linear_issue_create,
              :github_comment,
              :github_review_thread_resolve
            ],
       do: :ok

  defp validate_effect_type(effect_type), do: {:error, {:unsupported_effect_type, effect_type}}

  defp validate_fingerprint_fields(intent, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      if present?(intent, field), do: {:cont, :ok}, else: {:halt, {:error, {:missing_field, field}}}
    end)
  end

  defp validate_decoded_fingerprint({:symphony_request_fingerprint_v1, intent})
       when is_map(intent) do
    required = [
      :disposition,
      :finding_key,
      :finding_lineage_key,
      :evaluated_head_sha,
      :policy_version,
      :target,
      :payload,
      :resulting_tree_or_commit,
      :expected_transition
    ]

    with :ok <- validate_fingerprint_fields(intent, required),
         :ok <- validate_disposition(value(intent, :disposition)),
         :ok <- validate_sha(value(intent, :evaluated_head_sha), :evaluated_head_sha) do
      {:ok, intent}
    end
  end

  defp validate_decoded_fingerprint({version, _intent}),
    do: {:error, {:unknown_request_fingerprint_version, version}}

  defp validate_decoded_fingerprint(_term), do: {:error, :invalid_request_fingerprint}

  defp decode_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_request_fingerprint}
  end

  defp reconcile_lock_entry(entry, %{locks: locks} = state) when is_map(entry) do
    with {:ok, finding_digest} <- lock_finding_digest(entry),
         {:ok, disposition} <- required_present(entry, :disposition),
         :ok <- validate_disposition(disposition),
         :ok <- validate_lock_artifacts(entry) do
      merge_lock(state, locks, finding_digest, disposition, entry)
    end
  end

  defp reconcile_lock_entry(_entry, _state), do: {:error, :invalid_lock_entry}

  defp merge_lock(state, locks, finding_digest, disposition, entry) do
    case Map.get(locks, finding_digest) do
      nil -> {:ok, %{state | locks: Map.put(locks, finding_digest, entry)}}
      existing -> merge_existing_lock(state, existing, disposition)
    end
  end

  defp merge_existing_lock(state, existing, disposition) do
    if value(existing, :disposition) == disposition,
      do: {:ok, state},
      else: {:error, :conflicting_disposition_lock}
  end

  defp lock_finding_digest(entry) do
    case value(entry, :finding_key) do
      %{digest: digest} ->
        if non_empty_string?(digest), do: {:ok, digest}, else: {:error, :missing_finding_lock_identity}

      digest ->
        if non_empty_string?(digest), do: {:ok, digest}, else: {:error, :missing_finding_lock_identity}
    end
  end

  defp validate_lock_artifacts(entry) do
    artifacts =
      [:intent, :marker, :native_resource, :ledger_record]
      |> Enum.map(&value(entry, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&lock_identity/1)
      |> Enum.reject(&is_nil/1)

    if artifacts == [] or Enum.uniq(artifacts) |> length() == 1 do
      :ok
    else
      {:error, :conflicting_effect_lock}
    end
  end

  defp lock_identity(artifact) when is_map(artifact) do
    identity =
      artifact
      |> Map.take([:operation_id, :request_fingerprint, :disposition])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if identity == %{}, do: nil, else: identity
  end

  defp lock_identity(_artifact), do: nil

  defp global_preflight_blocker(preflight) do
    cond do
      value(preflight, :global_blocker) not in [nil, false] -> value(preflight, :global_blocker)
      value(preflight, :blocked?) == true -> :preflight_blocked
      value(preflight, :verified?) == false -> :preflight_unverified
      value(preflight, :valid?) == false -> :preflight_invalid
      true -> nil
    end
  end

  defp source_revalidation_guard(plan) do
    source = value(plan, :source_head_sha)
    evaluated = value(plan, :evaluated_head_sha)

    cond do
      is_nil(source) ->
        :ok

      not is_binary(source) ->
        {:error, :invalid_source_head_sha}

      source != evaluated and value(plan, :revalidated?) != true ->
        {:error, :source_head_requires_revalidation}

      true ->
        :ok
    end
  end

  defp current_head_guard(evaluated_head_sha, current_head_sha) do
    if evaluated_head_sha == current_head_sha, do: :ok, else: {:error, :current_head_drift}
  end

  defp required_string(input, key) do
    case value(input, key) do
      value ->
        if non_empty_string?(value), do: {:ok, value}, else: {:error, {:missing_or_invalid_field, key}}
    end
  end

  defp required_binary(input, key) do
    case value(input, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_or_invalid_field, key}}
    end
  end

  defp required_positive_integer(input, key) do
    case value(input, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:missing_or_invalid_field, key}}
    end
  end

  defp required_sha(input, key) do
    case value(input, key) do
      value when is_binary(value) ->
        case validate_sha(value, key) do
          :ok -> {:ok, value}
          error -> error
        end

      _ ->
        {:error, {:missing_or_invalid_field, key}}
    end
  end

  defp required_present(input, key) do
    if present?(input, key), do: {:ok, value(input, key)}, else: {:error, {:missing_field, key}}
  end

  defp fetch_required(input, key) do
    case required_present(input, key) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:missing_field, key}}
    end
  end

  defp validate_sha(value, _key) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, value), do: :ok, else: {:error, :invalid_head_sha}
  end

  defp validate_sha(_value, key), do: {:error, {:invalid_sha, key}}

  defp validate_disposition(disposition)
       when disposition in [
              :fix_in_current_pr,
              :follow_up_required,
              :blocked_unverified
            ],
       do: :ok

  defp validate_disposition(disposition), do: {:error, {:unknown_disposition, disposition}}

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil

  defp present?(map, key),
    do: is_map(map) and is_atom(key) and (Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)))

  defp non_empty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp digest(tag, value) do
    :crypto.hash(:sha256, :erlang.term_to_binary({tag, value}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp filter_disposition(decisions, disposition),
    do: Enum.filter(decisions, &(&1.disposition == disposition))
end
