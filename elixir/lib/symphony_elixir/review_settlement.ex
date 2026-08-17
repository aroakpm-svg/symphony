defmodule SymphonyElixir.ReviewSettlement do
  @moduledoc """
  Design 4 readback gate. Exact heads live on EvaluationKey. Resolve
  operation identity comes from ResolveAttemptKey. Receipts are built
  only through ReviewIdentity.
  """

  alias SymphonyElixir.{FindingDisposition, ReviewIdentity}

  @type result :: {:settled, map()} | {:blocked, term()}

  @spec settle(map(), map()) :: result()
  def settle(decision, context) when is_map(decision) and is_map(context) do
    with {:ok, finding_key, lineage_key} <- canonical_identity(decision),
         :ok <- active_claim(context),
         {:ok, evaluation_key} <- evaluation_key(decision, context, finding_key),
         :ok <- ReviewIdentity.exact_head(:current, evaluation_key, context[:current_head_sha]),
         :ok <- ReviewIdentity.exact_head(:evaluated, evaluation_key, context[:current_head_sha]),
         {:ok, resolve_attempt_key} <- resolve_attempt_key(context, evaluation_key),
         :ok <- no_unsafe_effects(context),
         identities <- {finding_key, lineage_key, evaluation_key, resolve_attempt_key},
         result <- settle_disposition(decision, context, identities) do
      result
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  def settle(_decision, _context), do: {:blocked, :invalid_settlement_input}

  defp canonical_identity(decision) do
    with finding_key when is_map(finding_key) <- decision[:finding_key],
         lineage_key when is_map(lineage_key) <- decision[:finding_lineage_key],
         {:ok, {finding_key, lineage_key}} <-
           FindingDisposition.validate_canonical_keys(finding_key, lineage_key),
         true <- decision[:finding_key_digest] == finding_key.digest do
      {:ok, finding_key, lineage_key}
    else
      _invalid -> {:error, :invalid_settlement_identity}
    end
  end

  defp active_claim(%{claim: %{active?: true, claim_id: claim_id, generation: generation}})
       when is_binary(claim_id) and claim_id != "" and is_integer(generation) and generation > 0,
       do: :ok

  defp active_claim(_context), do: {:error, :settlement_claim_unverified}

  defp evaluation_key(_decision, context, finding_key) do
    claim = context[:claim] || %{}

    ReviewIdentity.build_evaluation_key(%{
      finding_key: finding_key,
      source_head_sha: context[:source_head_sha] || context[:current_head_sha],
      evaluated_head_sha: context[:evaluated_head_sha] || context[:current_head_sha],
      current_head_sha: context[:current_head_sha],
      claim_id: claim[:claim_id],
      generation: claim[:generation]
    })
  end

  defp resolve_attempt_key(context, evaluation_key) do
    ReviewIdentity.build_resolve_attempt_key(%{
      evaluation_key: evaluation_key,
      thread_state: context[:thread_state] || :unresolved,
      prior_resolve_operation_id: context[:prior_resolve_operation_id],
      native_thread: native_thread(context, evaluation_key)
    })
  end

  defp native_thread(context, evaluation_key) do
    context[:native_thread] ||
      %{
        repository: evaluation_key.finding_key.repository,
        pull_request_number: evaluation_key.finding_key.pull_request_number,
        review_thread_id: evaluation_key.finding_key.review_thread_id,
        thread_state: context[:thread_state] || :unresolved,
        observed_head_sha: evaluation_key.current_head_sha
      }
  end

  defp no_unsafe_effects(context) do
    operations = context[:operations]

    cond do
      not is_list(operations) -> {:error, :settlement_operations_unavailable}
      Enum.any?(operations, &(&1[:status] in [:pending, :unknown])) -> {:error, :settlement_reconciliation_required}
      conflicting_operations?(operations) -> {:error, :settlement_operation_conflict}
      true -> :ok
    end
  end

  defp conflicting_operations?(operations) do
    operations
    |> Enum.group_by(& &1[:operation_id])
    |> Enum.any?(fn {_id, entries} ->
      entries
      |> Enum.map(&{&1[:effect_type], &1[:request_fingerprint]})
      |> Enum.uniq()
      |> length() > 1
    end)
  end

  defp settle_disposition(%{disposition: :blocked_unverified}, _context, _identities),
    do: {:blocked, :blocked_unverified}

  defp settle_disposition(
         %{disposition: :follow_up_required} = decision,
         context,
         {finding_key, lineage_key, evaluation_key, resolve_attempt_key}
       ) do
    context = Map.put(context, :canonical_follow_up_destination, decision[:follow_up_destination])

    with :ok <-
           succeeded_effect(
             context,
             :linear_issue_create,
             :follow_up_issue,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :follow_up_required
           ),
         {:ok, follow_up} <- follow_up_paths(decision, context, lineage_key),
         :ok <-
           succeeded_effect(
             context,
             :github_comment,
             :reply,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :follow_up_required
           ),
         {:ok, reply} <- reply_paths(context, finding_key, evaluation_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :follow_up_required
           ),
         {:ok, resolve} <- resolve_paths(context, finding_key, evaluation_key) do
      finish(
        :follow_up_settled,
        decision,
        context,
        finding_key,
        lineage_key,
        evaluation_key,
        resolve_attempt_key,
        %{follow_up: follow_up, reply: reply, resolve: resolve}
      )
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(
         %{disposition: :fix_in_current_pr} = decision,
         context,
         {finding_key, lineage_key, evaluation_key, resolve_attempt_key}
       ) do
    with :ok <- fix_evidence(context, evaluation_key),
         :ok <-
           succeeded_effect(
             context,
             :github_pr_update,
             :publish,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :fix_in_current_pr
           ),
         {:ok, publish} <- publish_paths(context, finding_key, evaluation_key),
         :ok <-
           succeeded_effect(
             context,
             :github_comment,
             :reply,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :fix_in_current_pr
           ),
         {:ok, reply} <- reply_paths(context, finding_key, evaluation_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :fix_in_current_pr
           ),
         {:ok, resolve} <- resolve_paths(context, finding_key, evaluation_key) do
      finish(
        :fix_settled,
        decision,
        context,
        finding_key,
        lineage_key,
        evaluation_key,
        resolve_attempt_key,
        %{publish: publish, reply: reply, resolve: resolve}
      )
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(
         %{disposition: :rejected} = decision,
         context,
         {finding_key, lineage_key, evaluation_key, resolve_attempt_key}
       ) do
    with :ok <- rejected_evidence(decision, context, finding_key, lineage_key, evaluation_key),
         :ok <-
           succeeded_effect(
             context,
             :github_comment,
             :reply,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :rejected
           ),
         {:ok, reply} <- reply_paths(context, finding_key, evaluation_key),
         :ok <- no_new_actionable_evidence(context),
         :ok <-
           succeeded_effect(
             context,
             :github_review_thread_resolve,
             :resolve,
             finding_key,
             lineage_key,
             evaluation_key,
             resolve_attempt_key,
             :rejected
           ),
         {:ok, resolve} <- resolve_paths(context, finding_key, evaluation_key) do
      finish(
        :rejected_settled,
        decision,
        context,
        finding_key,
        lineage_key,
        evaluation_key,
        resolve_attempt_key,
        %{reply: reply, resolve: resolve}
      )
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp settle_disposition(_decision, _context, _identities),
    do: {:blocked, :unsupported_settlement_disposition}

  defp finish(status, decision, context, finding_key, lineage_key, evaluation_key, resolve_attempt_key, paths) do
    with {:ok, resolve_op} <- ReviewIdentity.resolve_operation_identity(resolve_attempt_key),
         operation_ids <- receipt_operation_ids(context, resolve_op),
         {:ok, receipt} <-
           ReviewIdentity.build_settlement_receipt(%{
             finding_key: finding_key,
             finding_lineage_key: lineage_key,
             evaluation_key: evaluation_key,
             resolve_attempt_key: resolve_attempt_key,
             disposition: decision.disposition,
             settled_head_sha: evaluation_key.current_head_sha,
             published_head_sha: published_head(status, evaluation_key),
             operation_ids: operation_ids,
             native_resources: paths,
             native_readbacks: paths,
             evidence: %{status: status, reopened?: false, newer_actionable?: false}
           }) do
      {:settled,
       %{
         status: status,
         disposition: decision.disposition,
         finding_key: finding_key,
         finding_lineage_key: lineage_key,
         evaluation_key: evaluation_key,
         resolve_attempt_key: resolve_attempt_key,
         receipt: receipt,
         merge_authorized?: false
       }}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp published_head(:fix_settled, evaluation_key), do: evaluation_key.current_head_sha
  defp published_head(_status, _evaluation_key), do: nil

  defp receipt_operation_ids(context, resolve_op) do
    context[:operation_ids]
    |> Map.take([:reply, :follow_up_issue, :publish, :receipt])
    |> Map.put(:resolve, resolve_op)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp succeeded_effect(
         context,
         effect_type,
         role,
         finding_key,
         lineage_key,
         evaluation_key,
         resolve_attempt_key,
         disposition
       ) do
    expected_id = get_in(context, [:operation_ids, role])

    case expected_operation_id(
           effect_type,
           context,
           finding_key,
           lineage_key,
           evaluation_key,
           resolve_attempt_key,
           disposition
         ) do
      {:ok, ^expected_id} ->
        with {:ok, ledger_id} <- ledger_operation_id(context, expected_id) do
          validate_succeeded_effect(
            context,
            effect_type,
            role,
            ledger_id,
            disposition,
            finding_key,
            lineage_key,
            evaluation_key
          )
        end

      _invalid ->
        {:error, {:settlement_operation_identity_mismatch, role}}
    end
  end

  defp ledger_operation_id(context, operation_id) do
    case get_in(context, [:claim, :issue_id]) do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id <> ":" <> operation_id}
      _missing -> {:error, :settlement_issue_identity_unverified}
    end
  end

  defp validate_succeeded_effect(context, effect_type, role, expected_id, disposition, finding_key, lineage_key, evaluation_key) do
    matches =
      Enum.filter(context.operations, fn operation ->
        operation[:operation_id] == expected_id and operation[:effect_type] == effect_type
      end)

    case matches do
      [%{status: :succeeded, request_fingerprint: fingerprint, native_resource: native}]
      when is_binary(fingerprint) and fingerprint != "" and is_map(native) ->
        validate_fingerprint(fingerprint, disposition, finding_key, lineage_key, evaluation_key)

      [] ->
        {:error, {:settlement_effect_missing, role}}

      [%{status: :failed_no_effect}] ->
        {:error, {:settlement_effect_failed, role}}

      _entries ->
        {:error, {:settlement_effect_invalid, role}}
    end
  end

  defp expected_operation_id(:linear_issue_create, context, finding_key, lineage_key, _eval, _attempt, _disposition) do
    FindingDisposition.operation_id(:linear_issue_create, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      finding_lineage_key: lineage_key,
      destination: context[:canonical_follow_up_destination],
      effect_type: :linear_issue_create
    })
  end

  defp expected_operation_id(:github_pr_update, context, finding_key, _lineage, evaluation_key, _attempt, _disposition) do
    FindingDisposition.operation_id(:github_pr_update, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      evaluated_head_sha: evaluation_key.current_head_sha,
      finding_set_digest: get_in(context, [:path_evidence, :finding_set_digest]),
      authorization_identity: get_in(context, [:path_evidence, :authorization_identity]),
      effect_type: :github_pr_update
    })
  end

  defp expected_operation_id(:github_comment, _context, finding_key, _lineage, _eval, _attempt, disposition) do
    FindingDisposition.operation_id(:github_comment, %{
      repository: finding_key.repository,
      pull_request_number: finding_key.pull_request_number,
      review_thread_id: finding_key.review_thread_id,
      finding_key: finding_key,
      message_kind: message_kind(disposition),
      effect_type: :github_comment
    })
  end

  defp expected_operation_id(:github_review_thread_resolve, _context, _finding, _lineage, _eval, attempt, _disposition) do
    ReviewIdentity.resolve_operation_identity(attempt)
  end

  defp validate_fingerprint(fingerprint, disposition, finding_key, lineage_key, evaluation_key) do
    case FindingDisposition.decode_request_fingerprint(fingerprint) do
      {:ok, intent} ->
        if intent[:disposition] == disposition and intent[:finding_key] == finding_key and
             intent[:finding_lineage_key] == lineage_key and
             intent[:evaluated_head_sha] == evaluation_key.current_head_sha do
          :ok
        else
          {:error, :settlement_fingerprint_identity_mismatch}
        end

      _invalid ->
        {:error, :invalid_settlement_fingerprint}
    end
  end

  defp message_kind(:fix_in_current_pr), do: :fix
  defp message_kind(:follow_up_required), do: :follow_up
  defp message_kind(:rejected), do: :rejected

  defp follow_up_paths(decision, context, lineage_key) do
    destination = decision[:follow_up_destination]
    native = operation_native(context, :linear_issue_create)
    readback = path_readback(context, :follow_up)

    issue_id = resource_value(native, :id) || resource_value(native, :issue_id)
    readback_id = resource_value(readback, :id) || resource_value(readback, :issue_id)
    identifier = resource_value(readback, :identifier) || issue_id
    state = resource_value(readback, :state)

    cond do
      not same_id?(issue_id, readback_id) ->
        {:error, {:settlement_native_resource_mismatch, :follow_up_issue}}

      not follow_up_readback?(readback, destination, state, lineage_key) ->
        {:error, :follow_up_readback_unverified}

      true ->
        {:ok,
         %{
           issue_id: issue_id,
           identifier: identifier,
           destination: destination,
           state: state,
           lineage_digest: lineage_key.digest
         }}
    end
  end

  defp follow_up_readback?(readback, destination, state, lineage_key) do
    resource_value(readback, :destination) == destination and present_string?(destination) and
      present_string?(state) and
      resource_value(readback, :finding_lineage_key_digest) in [nil, lineage_key.digest]
  end

  defp reply_paths(context, finding_key, evaluation_key) do
    native = operation_native(context, :github_comment)
    readback = path_readback(context, :reply)
    reply_body = context[:reply_body]
    comment_id = resource_value(native, :comment_id) || resource_value(native, :id)
    readback_id = resource_value(readback, :comment_id) || resource_value(readback, :id)

    cond do
      not same_id?(comment_id, readback_id) ->
        {:error, {:settlement_native_resource_mismatch, :reply}}

      not present_string?(reply_body) or resource_value(readback, :body) != reply_body ->
        {:error, :reply_readback_unverified}

      resource_value(readback, :head_sha) != evaluation_key.current_head_sha ->
        {:error, :reply_readback_unverified}

      resource_value(readback, :finding_key_digest) not in [nil, finding_key.digest] ->
        {:error, :reply_readback_unverified}

      true ->
        {:ok,
         %{
           comment_id: comment_id,
           repository: finding_key.repository,
           pull_request_number: finding_key.pull_request_number,
           thread_id: finding_key.review_thread_id,
           body_sha256: sha256(reply_body),
           head_sha: evaluation_key.current_head_sha
         }}
    end
  end

  defp resolve_paths(context, finding_key, evaluation_key) do
    native = operation_native(context, :github_review_thread_resolve)
    readback = path_readback(context, :resolve) || path_readback(context, :thread)

    thread_id = resolve_thread_id(native)
    readback_thread = resolve_thread_id(readback)
    resolved? = resolve_resolved?(readback)
    observed = resolve_observed_head(readback)

    cond do
      not same_id?(thread_id, readback_thread) ->
        {:error, {:settlement_native_resource_mismatch, :resolve}}

      not resolved? ->
        {:error, :resolve_readback_unverified}

      not resolve_identity?(readback, finding_key, evaluation_key, observed) ->
        {:error, :resolve_readback_identity_mismatch}

      true ->
        {:ok,
         %{
           review_thread_id: finding_key.review_thread_id,
           repository: finding_key.repository,
           pull_request_number: finding_key.pull_request_number,
           resolved: true,
           observed_head_sha: evaluation_key.current_head_sha
         }}
    end
  end

  defp resolve_identity?(readback, finding_key, evaluation_key, observed) do
    observed == evaluation_key.current_head_sha and
      resource_value(readback, :repository) == finding_key.repository and
      resource_value(readback, :pull_request_number) == finding_key.pull_request_number
  end

  defp resolve_thread_id(resource) do
    resource_value(resource, :review_thread_id) || resource_value(resource, :thread_id) ||
      resource_value(resource, :id)
  end

  defp resolve_resolved?(readback) do
    true_value?(resource_value(readback, :resolved) || resource_value(readback, :resolved?))
  end

  defp resolve_observed_head(readback) do
    resource_value(readback, :observed_head_sha) || resource_value(readback, :head_sha)
  end

  defp publish_paths(context, finding_key, evaluation_key) do
    native = operation_native(context, :github_pr_update)
    readback = path_readback(context, :publish)
    native_commit = resource_value(native, :commit_sha)
    readback_commit = resource_value(readback, :commit_sha)
    native_tree = resource_value(native, :tree_sha)
    readback_tree = resource_value(readback, :tree_sha)

    if same_id?(native_commit, readback_commit) and native_commit == evaluation_key.current_head_sha and
         same_id?(native_tree, readback_tree) do
      {:ok,
       %{
         commit_sha: native_commit,
         tree_sha: native_tree,
         repository: finding_key.repository,
         pull_request_number: finding_key.pull_request_number
       }}
    else
      {:error, {:settlement_native_resource_mismatch, :publish}}
    end
  end

  defp no_new_actionable_evidence(context) do
    readback = context[:native_readbacks] || context[:native_readback] || %{}

    cond do
      readback[:reopened?] == true -> {:error, :review_thread_reopened}
      newer_actionable?(readback) -> {:error, :newer_trusted_actionable_finding}
      readback[:reopened?] != false -> {:error, :review_thread_reopen_status_unverified}
      not newer_actionable_verified?(readback) -> {:error, :newer_actionable_status_unverified}
      true -> :ok
    end
  end

  defp newer_actionable?(readback),
    do: readback[:newer_actionable?] == true or readback[:newer_trusted_actionable?] == true

  defp newer_actionable_verified?(readback),
    do: readback[:newer_actionable?] == false or readback[:newer_trusted_actionable?] == false

  defp fix_evidence(context, evaluation_key) do
    case context[:path_evidence] do
      %{
        managed_publish_confirmed?: true,
        regression_status: :pass,
        accepted_review_head_sha: head_sha,
        authorization_identity: authorization_identity,
        finding_set_digest: finding_set_digest
      }
      when head_sha == evaluation_key.current_head_sha and is_binary(authorization_identity) and
             authorization_identity != "" and is_binary(finding_set_digest) and
             byte_size(finding_set_digest) == 64 ->
        :ok

      _evidence ->
        {:error, :fix_settlement_evidence_unverified}
    end
  end

  defp rejected_evidence(decision, context, finding_key, lineage_key, evaluation_key) do
    receipt = get_in(decision, [:facts, :root_cause_receipt]) || %{}

    with {:ok, {receipt_finding, _lineage}} <-
           FindingDisposition.validate_canonical_keys(
             value(receipt, :finding_key),
             value(receipt, :finding_lineage_key)
           ),
         true <- receipt_finding == finding_key,
         true <- value(receipt, :disposition) in [:reject, "reject"],
         true <- value(receipt, :verified?) == true and value(receipt, :valid?) == true,
         true <- value(receipt, :validation_receipt_status) in [:pass, "PASS"],
         true <- present_string?(value(receipt, :rejection_basis)),
         true <- is_list(value(receipt, :evidence_references)) and value(receipt, :evidence_references) != [],
         true <- value(receipt, :evaluated_head_sha) == evaluation_key.current_head_sha,
         true <- value(receipt, :current_head_sha) == context[:current_head_sha] do
      _ = lineage_key
      :ok
    else
      _invalid -> {:error, :rejection_proof_unverified}
    end
  end

  defp operation_native(context, effect_type) do
    context[:operations]
    |> List.wrap()
    |> Enum.find(%{}, &(&1[:effect_type] == effect_type))
    |> Map.get(:native_resource, %{})
  end

  defp path_readback(context, role) do
    readbacks = context[:native_readbacks] || context[:native_readback] || %{}
    readbacks[role] || readbacks[Atom.to_string(role)]
  end

  defp same_id?(left, right), do: present_string?(left) and left == right

  defp present_string?(value), do: is_binary(value) and value != ""

  defp true_value?(value), do: value == true

  defp resource_value(resource, key) when is_map(resource),
    do: Map.get(resource, key) || Map.get(resource, Atom.to_string(key))

  defp resource_value(_resource, _key), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
