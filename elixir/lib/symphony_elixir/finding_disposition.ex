defmodule SymphonyElixir.FindingDisposition do
  @moduledoc """
  Pure Design 2 contract for identifying, classifying, and ordering review findings.

  This module only consumes normalized provider facts. It deliberately has no
  GitHub, Linear, claim, ledger, persistence, or callback dependency.
  """

  @type disposition ::
          :fix_in_current_pr | :follow_up_required | :blocked_unverified | :rejected
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
          rejected_decisions: [decision()],
          merge_ready_blocked?: boolean(),
          preflight: map()
        }

  @type effect_intent :: map()
  @type managed_publish_identity :: map()

  @supported_message_kinds [:follow_up]

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
      resolved? = true_value?(value(thread, :resolved?))

      if resolved? do
        select_resolved_comment(thread, options, candidates)
      else
        select_unresolved_comment(candidates)
      end
    end
  end

  def select_review_comment(_thread, _options), do: {:error, :invalid_review_thread}

  @spec classify(map(), map()) :: {:ok, decision()} | {:error, term()}
  def classify(facts, preflight) when is_map(facts) and is_map(preflight) do
    case canonical_identity(facts) do
      {:ok, {finding_key, finding_lineage_key, finding_key_digest}} ->
        {:ok,
         %{
           disposition: classify_disposition(facts, finding_key, finding_lineage_key, preflight),
           finding_key: finding_key,
           finding_key_digest: finding_key_digest,
           finding_lineage_key: finding_lineage_key,
           facts: facts
         }}

      {:error, _reason} ->
        {:ok,
         %{
           disposition: :blocked_unverified,
           finding_key: nil,
           finding_key_digest: fallback_digest(facts),
           finding_lineage_key: nil,
           facts: facts
         }}
    end
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
        rejected_decisions = Enum.filter(decisions, &(&1.disposition == :rejected))

        {:ok,
         %{
           decisions: decisions,
           fix_decisions: fix_decisions,
           follow_up_decisions: follow_up_decisions,
           blocked_decisions: blocked_decisions,
           rejected_decisions: rejected_decisions,
           merge_ready_blocked?: blocked_decisions != [] or rejected_decisions != [],
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

  @spec validate_canonical_keys(map(), map()) ::
          {:ok, {finding_key(), finding_lineage_key()}} | {:error, term()}
  def validate_canonical_keys(finding_key, finding_lineage_key) do
    with {:ok, finding_key} <- canonical_finding_key(finding_key),
         {:ok, finding_lineage_key} <- canonical_lineage_key(finding_lineage_key),
         :ok <- matching_finding_scope(finding_key, finding_lineage_key) do
      {:ok, {finding_key, finding_lineage_key}}
    end
  end

  defp matching_finding_scope(finding_key, finding_lineage_key) do
    if finding_key.repository == finding_lineage_key.repository and
         finding_key.pull_request_number == finding_lineage_key.pull_request_number and
         finding_key.review_thread_id == finding_lineage_key.review_thread_id do
      :ok
    else
      {:error, :finding_lineage_scope_mismatch}
    end
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
         :ok <- validate_sha(value(intent, :evaluated_head_sha), :evaluated_head_sha),
         :ok <- validate_fingerprint_identity(intent) do
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
    rejected_decisions = Map.get(plan, :rejected_decisions, filter_disposition(decisions, :rejected))

    [
      :reconcile,
      {:retain_rejected_for_settlement, rejected_decisions},
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

  defp classify_disposition(facts, finding_key, finding_lineage_key, preflight) do
    cond do
      rejected_facts?(facts, finding_key, finding_lineage_key, preflight) -> :rejected
      reject_receipt_attempted?(facts) -> :blocked_unverified
      fix_facts?(facts) -> :fix_in_current_pr
      follow_up_facts?(facts) -> :follow_up_required
      true -> :blocked_unverified
    end
  end

  defp reject_receipt_attempted?(facts) do
    case value(facts, :root_cause_receipt) do
      receipt when is_map(receipt) -> value(receipt, :disposition) in [:reject, "reject"]
      _receipt -> false
    end
  end

  defp rejected_facts?(facts, finding_key, finding_lineage_key, preflight) do
    with receipt when is_map(receipt) <- value(facts, :root_cause_receipt),
         disposition when disposition in [:reject, "reject"] <- value(receipt, :disposition),
         true <- true_value?(value(receipt, :verified?)),
         true <- true_value?(value(receipt, :valid?)),
         true <- no_evidence_conflict?(facts),
         true <- no_evidence_conflict?(receipt),
         true <- non_blank_string?(value(receipt, :rejection_basis)),
         true <- non_blank_string_list?(value(receipt, :evidence_references)),
         true <- value(receipt, :review_action) in [:unresolved_with_reason, "unresolved_with_reason"],
         true <- value(receipt, :validation_receipt_status) in [:pass, "PASS"],
         false <- value(receipt, :hypothesis_rejected?),
         {:ok, receipt_finding_key} <- canonical_finding_key(value(receipt, :finding_key)),
         {:ok, receipt_lineage_key} <- canonical_lineage_key(value(receipt, :finding_lineage_key)),
         true <- receipt_finding_key == finding_key,
         true <- receipt_lineage_key == finding_lineage_key,
         source_head_sha when is_binary(source_head_sha) <- finding_key.source_head_sha,
         true <- value(preflight, :current_head_sha) == source_head_sha,
         true <- value(receipt, :evaluated_head_sha) == source_head_sha,
         true <- value(receipt, :current_head_sha) == source_head_sha,
         native_readback when is_map(native_readback) <- value(receipt, :native_readback),
         true <- rejection_readback_matches?(native_readback, finding_key, finding_lineage_key) do
      true
    else
      _ -> false
    end
  end

  defp rejection_readback_matches?(readback, finding_key, finding_lineage_key) do
    true_value?(value(readback, :verified?)) and
      value(readback, :repository) == finding_key.repository and
      value(readback, :pull_request_number) == finding_key.pull_request_number and
      value(readback, :review_thread_id) == finding_key.review_thread_id and
      value(readback, :current_head_sha) == finding_key.source_head_sha and
      value(readback, :finding_key_digest) == finding_key.digest and
      value(readback, :finding_lineage_key_digest) == finding_lineage_key.digest
  end

  defp fix_facts?(facts) do
    responsibility_proven?(facts) and
      true_value?(value(facts, :still_applies?)) and
      true_value?(value(facts, :root_cause_bounded?)) and
      false_value?(value(facts, :requires_new_decision?))
  end

  defp follow_up_facts?(facts) do
    with {:ok, _ownership} <- ownership_evidence(facts),
         true <- true_value?(value(facts, :safe_follow_up?)),
         true <- false_value?(value(facts, :in_scope?)),
         true <- true_value?(value(facts, :still_applies?)),
         true <- true_value?(value(facts, :root_cause_bounded?)),
         true <- non_empty_string?(value(facts, :follow_up_destination)),
         true <- false_value?(value(facts, :requires_new_decision?)) do
      true
    else
      _ -> false
    end
  end

  defp responsibility_proven?(facts) do
    case ownership_evidence(facts) do
      {:ok, %{introduced_by_pr?: introduced_by_pr?, invariant_violation?: invariant_violation?}} ->
        true_value?(introduced_by_pr?) or true_value?(invariant_violation?)

      _ ->
        false
    end
  end

  defp ownership_evidence(facts) do
    with {:ok, introduced_by_pr?} <- ownership_evidence_flag(facts, :introduced_by_pr?),
         {:ok, invariant_violation?} <- ownership_evidence_flag(facts, :invariant_violation?),
         true <- is_boolean(introduced_by_pr?) and is_boolean(invariant_violation?),
         true <- no_evidence_conflict?(facts) do
      {:ok, %{introduced_by_pr?: introduced_by_pr?, invariant_violation?: invariant_violation?}}
    else
      _ -> {:error, :invalid_ownership_evidence}
    end
  end

  defp ownership_evidence_flag(facts, key) do
    if present?(facts, key) do
      case value(facts, key) do
        value when is_boolean(value) or value == :unknown -> {:ok, value}
        _ -> {:error, {:invalid_ownership_evidence, key}}
      end
    else
      {:error, {:missing_ownership_evidence, key}}
    end
  end

  defp no_evidence_conflict?(facts) do
    case value(facts, :evidence_conflict?) do
      nil -> true
      value when is_boolean(value) -> not value
      _ -> false
    end
  end

  defp canonical_identity(facts) do
    case build_finding_key(facts) do
      {:ok, finding_key} ->
        with {:ok, lineage_key} <- build_lineage_key(facts),
             :ok <- supplied_identity_matches(facts, :finding_key, finding_key),
             :ok <- supplied_identity_matches(facts, :finding_lineage_key, lineage_key) do
          {:ok, {finding_key, lineage_key, finding_key.digest}}
        end

      {:error, _reason} ->
        canonical_supplied_identity(facts)
    end
  end

  defp canonical_supplied_identity(facts) do
    with {:ok, finding_key} <- canonical_finding_key(value(facts, :finding_key)),
         {:ok, derived_lineage_key} <- build_lineage_key(finding_key),
         {:ok, lineage_key} <- supplied_lineage_key(facts, derived_lineage_key),
         :ok <- matching_lineage_identity(finding_key, lineage_key) do
      {:ok, {finding_key, lineage_key, finding_key.digest}}
    end
  end

  defp supplied_lineage_key(facts, derived_lineage_key) do
    case value(facts, :finding_lineage_key) do
      nil -> {:ok, derived_lineage_key}
      supplied -> canonical_lineage_key(supplied)
    end
  end

  defp supplied_identity_matches(facts, key, expected) do
    if present?(facts, key) and value(facts, key) != expected,
      do: {:error, {:non_canonical_supplied_identity, key}},
      else: :ok
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
    if true_value?(value(comment, :trusted_review_source?)) and
         not_true_value?(value(comment, :managed_agent_reply?)) and
         not_true_value?(value(comment, :settlement_marker?)) do
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
      candidates == [] ->
        :no_fresh_evidence

      not non_empty_string?(thread_id) or not is_map(settled) ->
        {:error, :resolved_thread_settlement_unverified}

      not Map.has_key?(settled, thread_id) ->
        {:error, :resolved_thread_settlement_unverified}

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
    with {:ok, _base_identity} <- required_identity(input, [:repository, :pull_request_number]),
         :ok <- matching_effect_type(input, :linear_issue_create),
         {:ok, lineage} <- logical_identity_field(input, :finding_lineage_key),
         :ok <-
           matching_operation_scope(input, lineage, :finding_lineage_key, [
             :repository,
             :pull_request_number
           ]),
         {:ok, destination} <- logical_identity_field(input, :destination) do
      identity = [value(input, :repository), value(input, :pull_request_number), lineage, destination]
      {:ok, identity ++ [:linear_issue_create]}
    end
  end

  defp logical_operation_identity(:github_comment, input) do
    with {:ok, _base_identity} <- required_identity(input, [:repository, :pull_request_number, :review_thread_id]),
         :ok <- matching_effect_type(input, :github_comment),
         {:ok, finding_identity} <- required_finding_identity(input),
         :ok <-
           matching_operation_scope(input, finding_identity, :finding_key, [
             :repository,
             :pull_request_number,
             :review_thread_id
           ]),
         {:ok, message_kind} <- logical_identity_field(input, :message_kind) do
      identity = {review_identity(input), finding_identity, message_kind, :github_comment}

      {:ok, identity}
    end
  end

  defp logical_operation_identity(:github_review_thread_resolve, input) do
    with {:ok, _base_identity} <- required_identity(input, [:repository, :pull_request_number, :review_thread_id]),
         :ok <- matching_effect_type(input, :github_review_thread_resolve),
         {:ok, lineage} <- logical_identity_field(input, :finding_lineage_key),
         :ok <-
           matching_operation_scope(input, lineage, :finding_lineage_key, [
             :repository,
             :pull_request_number,
             :review_thread_id
           ]) do
      identity = {review_identity(input), lineage, :github_review_thread_resolve}

      {:ok, identity}
    end
  end

  defp required_finding_identity(input) do
    cond do
      present?(input, :finding_key) -> logical_identity_field(input, :finding_key)
      present?(input, :finding_lineage_key) -> logical_identity_field(input, :finding_lineage_key)
      true -> {:error, {:missing_field, :finding_key_or_lineage_key}}
    end
  end

  defp matching_operation_scope(input, identity, field, scope_fields) when is_map(identity) do
    if Enum.all?(scope_fields, &(value(input, &1) == value(identity, &1))),
      do: :ok,
      else: {:error, {:logical_identity_scope_mismatch, field}}
  end

  defp matching_operation_scope(_input, _identity, _field, _scope_fields), do: :ok

  defp matching_effect_type(input, expected) do
    case logical_identity_field(input, :effect_type) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:effect_type_mismatch, expected, actual}}
      error -> error
    end
  end

  defp review_identity(input),
    do: {value(input, :repository), value(input, :pull_request_number), value(input, :review_thread_id)}

  defp required_identity(input, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case logical_identity_field(input, field) do
        {:ok, _value} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.map(fields, &value(input, &1))}
      error -> error
    end
  end

  defp logical_identity_field(input, field) do
    case required_present(input, field) do
      {:error, reason} ->
        {:error, reason}

      {:ok, value} ->
        if valid_logical_identity?(field, value),
          do: {:ok, normalize_logical_identity(field, value)},
          else: {:error, {:invalid_logical_identity, field}}
    end
  end

  defp normalize_logical_identity(:message_kind, value) when is_binary(value) do
    Enum.find(@supported_message_kinds, &(Atom.to_string(&1) == value))
  end

  defp normalize_logical_identity(_field, value), do: value

  defp valid_logical_identity?(:repository, value), do: valid_repository?(value)
  defp valid_logical_identity?(:pull_request_number, value), do: is_integer(value) and value > 0
  defp valid_logical_identity?(:evaluated_head_sha, value), do: validate_sha(value, :evaluated_head_sha) == :ok
  defp valid_logical_identity?(:finding_set_digest, value), do: valid_digest?(value)
  defp valid_logical_identity?(:authorization_identity, value), do: non_empty_string?(value)
  defp valid_logical_identity?(:finding_key, value), do: valid_canonical_key_or_digest?(value, :finding_key)
  defp valid_logical_identity?(:finding_lineage_key, value), do: valid_canonical_key_or_digest?(value, :finding_lineage_key)
  defp valid_logical_identity?(:review_thread_id, value), do: non_empty_string?(value)
  defp valid_logical_identity?(:destination, value), do: non_empty_string?(value)

  defp valid_logical_identity?(:message_kind, value),
    do:
      value in @supported_message_kinds or
        (is_binary(value) and Enum.any?(@supported_message_kinds, &(Atom.to_string(&1) == value)))

  defp valid_logical_identity?(:effect_type, value), do: validate_effect_type(value) == :ok

  defp valid_repository?(value) do
    is_binary(value) and Regex.match?(~r/\A[^\/\s]+\/[^\/\s]+\z/, value)
  end

  defp valid_digest?(value) do
    is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  end

  defp valid_canonical_key_or_digest?(value, :finding_key) when is_map(value),
    do: match?({:ok, _key}, canonical_finding_key(value))

  defp valid_canonical_key_or_digest?(value, :finding_lineage_key) when is_map(value),
    do: match?({:ok, _key}, canonical_lineage_key(value))

  defp valid_canonical_key_or_digest?(value, _key), do: valid_digest?(value)

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
         :ok <- validate_sha(value(intent, :evaluated_head_sha), :evaluated_head_sha),
         :ok <- validate_fingerprint_identity(intent) do
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
      blocker_present?(value(preflight, :global_blocker)) -> value(preflight, :global_blocker)
      true_value?(value(preflight, :blocked?)) -> :preflight_blocked
      true_value?(value(preflight, :conflict?)) -> :preflight_conflicting
      not true_value?(value(preflight, :verified?)) -> :preflight_unverified
      not true_value?(value(preflight, :valid?)) -> :preflight_invalid
      true -> nil
    end
  end

  defp validate_fingerprint_identity(intent) do
    with {:ok, finding_key} <- canonical_finding_key(value(intent, :finding_key)),
         {:ok, lineage_key} <- canonical_lineage_key(value(intent, :finding_lineage_key)),
         :ok <- matching_lineage_identity(finding_key, lineage_key) do
      matching_target_identity(value(intent, :target), finding_key)
    end
  end

  defp canonical_finding_key(key) when is_map(key) do
    with {:ok, repository} <- required_string(key, :repository),
         {:ok, pull_request_number} <- required_positive_integer(key, :pull_request_number),
         {:ok, source_head_sha} <- required_sha(key, :source_head_sha),
         {:ok, review_thread_id} <- required_string(key, :review_thread_id),
         {:ok, selected_review_comment_id} <- required_string(key, :selected_review_comment_id),
         {:ok, body_sha256} <- required_digest(key, :body_sha256),
         {:ok, _digest_value} <- required_digest(key, :digest) do
      identity =
        {repository, pull_request_number, source_head_sha, review_thread_id, selected_review_comment_id, body_sha256}

      expected = %{
        repository: repository,
        pull_request_number: pull_request_number,
        source_head_sha: source_head_sha,
        review_thread_id: review_thread_id,
        selected_review_comment_id: selected_review_comment_id,
        body_sha256: body_sha256,
        digest: digest(:symphony_finding_identity_v1, identity)
      }

      if key == expected, do: {:ok, expected}, else: {:error, :non_canonical_finding_key}
    end
  end

  defp canonical_finding_key(_key), do: {:error, :invalid_finding_key}

  defp canonical_lineage_key(key) when is_map(key) do
    with {:ok, repository} <- required_string(key, :repository),
         {:ok, pull_request_number} <- required_positive_integer(key, :pull_request_number),
         {:ok, review_thread_id} <- required_string(key, :review_thread_id),
         {:ok, _digest_value} <- required_digest(key, :digest) do
      expected = %{
        repository: repository,
        pull_request_number: pull_request_number,
        review_thread_id: review_thread_id,
        digest: digest(:symphony_finding_lineage_v1, {repository, pull_request_number, review_thread_id})
      }

      if key == expected, do: {:ok, expected}, else: {:error, :non_canonical_finding_lineage_key}
    end
  end

  defp canonical_lineage_key(_key), do: {:error, :invalid_finding_lineage_key}

  defp matching_lineage_identity(finding_key, lineage_key) do
    if finding_key.repository == lineage_key.repository and
         finding_key.pull_request_number == lineage_key.pull_request_number and
         finding_key.review_thread_id == lineage_key.review_thread_id do
      :ok
    else
      {:error, :finding_lineage_scope_mismatch}
    end
  end

  defp matching_target_identity(target, finding_key) when is_map(target) do
    if value(target, :repository) == finding_key.repository and
         value(target, :pull_request_number) == finding_key.pull_request_number do
      :ok
    else
      {:error, :finding_target_scope_mismatch}
    end
  end

  defp matching_target_identity(_target, _finding_key), do: {:error, :invalid_finding_target}

  defp required_digest(input, key) do
    case value(input, key) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: {:ok, value}, else: {:error, {:invalid_digest, key}}

      _ ->
        {:error, {:invalid_digest, key}}
    end
  end

  defp source_revalidation_guard(plan) do
    source = value(plan, :source_head_sha)
    evaluated = value(plan, :evaluated_head_sha)

    case validate_sha(source, :source_head_sha) do
      {:error, _reason} ->
        {:error, :invalid_source_head_sha}

      :ok ->
        if source != evaluated and not_true_value?(value(plan, :revalidated?)) do
          {:error, :source_head_requires_revalidation}
        else
          :ok
        end
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
              :blocked_unverified,
              :rejected
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

  defp present?(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, _value} -> true
      :error -> Map.has_key?(map, Atom.to_string(key))
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp non_blank_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp non_blank_string_list?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &non_blank_string?/1)

  defp non_blank_string_list?(_values), do: false

  defp false_value?(value), do: is_boolean(value) and not value

  defp blocker_present?(value), do: not is_nil(value) and (not is_boolean(value) or value)

  defp true_value?(value), do: is_boolean(value) and value

  defp not_true_value?(value), do: not is_boolean(value) or not value

  defp digest(tag, value) do
    :crypto.hash(:sha256, :erlang.term_to_binary({tag, value}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp filter_disposition(decisions, disposition),
    do: Enum.filter(decisions, &(&1.disposition == disposition))
end
