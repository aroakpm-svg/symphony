defmodule SymphonyElixir.ReviewIdentity do
  @moduledoc """
  Canonical identity algebra for Design 2/4 settlement.

  FindingKey identifies a review finding without head. Heads live on
  EvaluationKey. Resolve attempts include a durable/native-derived
  reopen epoch. Settlement receipts are append-only and immutable.
  """

  @sha_re ~r/\A[0-9a-f]{40}\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/
  @dispositions [:fix_in_current_pr, :follow_up_required, :rejected]
  @thread_states [:resolved, :unresolved]

  @type finding_key :: %{
          repository: String.t(),
          pull_request_number: pos_integer(),
          review_thread_id: String.t(),
          selected_review_comment_id: String.t(),
          body_sha256: String.t(),
          digest: String.t()
        }

  @type lineage_key :: %{
          repository: String.t(),
          pull_request_number: pos_integer(),
          review_thread_id: String.t(),
          digest: String.t()
        }

  @type evaluation_key :: %{
          finding_key: finding_key(),
          source_head_sha: String.t(),
          evaluated_head_sha: String.t(),
          current_head_sha: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          digest: String.t()
        }

  @type resolve_attempt_key :: %{
          evaluation_key: evaluation_key(),
          reopen_epoch: String.t(),
          digest: String.t()
        }

  @type settlement_receipt :: %{
          finding_key: finding_key(),
          finding_lineage_key: lineage_key(),
          evaluation_key: evaluation_key(),
          resolve_attempt_key: resolve_attempt_key(),
          disposition: atom(),
          source_head_sha: String.t(),
          evaluated_head_sha: String.t(),
          current_head_sha: String.t(),
          published_head_sha: String.t() | nil,
          settled_head_sha: String.t(),
          operation_ids: map(),
          native_resources: map(),
          evidence: map(),
          evidence_sha256: String.t(),
          digest: String.t()
        }

  @spec build_finding_key(map()) :: {:ok, finding_key()} | {:error, term()}
  def build_finding_key(input) when is_map(input) do
    with {:ok, repository} <- required_string(input, :repository),
         {:ok, pull_request_number} <- required_positive_integer(input, :pull_request_number),
         {:ok, review_thread_id} <- required_string(input, :review_thread_id),
         {:ok, selected_review_comment_id} <- required_string(input, :selected_review_comment_id),
         {:ok, body_sha256} <- required_digest(input, :body_sha256) do
      digest =
        digest(:symphony_finding_identity_v2, {
          repository,
          pull_request_number,
          review_thread_id,
          selected_review_comment_id,
          body_sha256
        })

      {:ok,
       %{
         repository: repository,
         pull_request_number: pull_request_number,
         review_thread_id: review_thread_id,
         selected_review_comment_id: selected_review_comment_id,
         body_sha256: body_sha256,
         digest: digest
       }}
    end
  end

  def build_finding_key(_input), do: {:error, :invalid_finding_key_input}

  @spec build_lineage_key(map()) :: {:ok, lineage_key()} | {:error, term()}
  def build_lineage_key(input) when is_map(input) do
    with {:ok, repository} <- required_string(input, :repository),
         {:ok, pull_request_number} <- required_positive_integer(input, :pull_request_number),
         {:ok, review_thread_id} <- required_string(input, :review_thread_id) do
      digest =
        digest(:symphony_finding_lineage_v2, {repository, pull_request_number, review_thread_id})

      {:ok,
       %{
         repository: repository,
         pull_request_number: pull_request_number,
         review_thread_id: review_thread_id,
         digest: digest
       }}
    end
  end

  def build_lineage_key(_input), do: {:error, :invalid_lineage_key_input}

  @spec build_evaluation_key(map()) :: {:ok, evaluation_key()} | {:error, term()}
  def build_evaluation_key(input) when is_map(input) do
    with {:ok, finding_key} <- fetch_finding_key(input),
         {:ok, source_head_sha} <- required_sha(input, :source_head_sha),
         {:ok, evaluated_head_sha} <- required_sha(input, :evaluated_head_sha),
         {:ok, current_head_sha} <- required_sha(input, :current_head_sha),
         {:ok, claim_id} <- required_string(input, :claim_id),
         {:ok, generation} <- required_positive_integer(input, :generation) do
      digest =
        digest(:symphony_evaluation_identity_v1, {
          finding_key.digest,
          source_head_sha,
          evaluated_head_sha,
          current_head_sha,
          claim_id,
          generation
        })

      {:ok,
       %{
         finding_key: finding_key,
         source_head_sha: source_head_sha,
         evaluated_head_sha: evaluated_head_sha,
         current_head_sha: current_head_sha,
         claim_id: claim_id,
         generation: generation,
         digest: digest
       }}
    end
  end

  def build_evaluation_key(_input), do: {:error, :invalid_evaluation_key_input}

  @spec derive_reopen_epoch(map()) :: {:ok, String.t()} | {:error, term()}
  def derive_reopen_epoch(input) when is_map(input) do
    with {:ok, evaluation_key} <- fetch_evaluation_key(input),
         {:ok, thread_state} <- required_thread_state(input),
         {:ok, native_readback} <- required_native_thread_readback(input, evaluation_key),
         :ok <- matching_observed_head(native_readback, evaluation_key),
         :ok <- matching_native_thread_state(native_readback, thread_state) do
      prior = optional_digest(input, :prior_resolve_operation_id)

      cond do
        thread_state == :unresolved and is_nil(prior) ->
          {:ok, digest(:symphony_reopen_epoch_v1, {:initial, evaluation_key.digest})}

        thread_state == :unresolved and is_binary(prior) ->
          {:ok, digest(:symphony_reopen_epoch_v1, {:reopened, prior, native_readback})}

        thread_state == :resolved and is_binary(prior) ->
          {:ok, digest(:symphony_reopen_epoch_v1, {:same_cycle, prior, evaluation_key.digest})}

        thread_state == :resolved and is_nil(prior) ->
          {:error, :resolved_without_prior_resolve}
      end
    end
  end

  def derive_reopen_epoch(_input), do: {:error, :invalid_reopen_epoch_input}

  @spec build_resolve_attempt_key(map()) :: {:ok, resolve_attempt_key()} | {:error, term()}
  def build_resolve_attempt_key(input) when is_map(input) do
    with {:ok, evaluation_key} <- fetch_evaluation_key(input),
         {:ok, reopen_epoch} <- fetch_reopen_epoch(input) do
      digest =
        digest(:symphony_resolve_attempt_v1, {evaluation_key.digest, reopen_epoch})

      {:ok,
       %{
         evaluation_key: evaluation_key,
         reopen_epoch: reopen_epoch,
         digest: digest
       }}
    end
  end

  def build_resolve_attempt_key(_input), do: {:error, :invalid_resolve_attempt_key_input}

  @spec evidence_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def evidence_digest(evidence) when is_map(evidence) do
    if Map.get(evidence, :recovered_from_pending_receipt?) == true or
         Map.get(evidence, "recovered_from_pending_receipt?") == true do
      {:error, :synthetic_terminal_evidence}
    else
      with {:ok, status} <- required_atom(evidence, :status),
           {:ok, native_confirmed?} <- required_boolean(evidence, :native_confirmed?) do
        {:ok, digest(:symphony_settlement_evidence_v1, {status, native_confirmed?})}
      else
        {:error, _reason} -> {:error, :invalid_settlement_evidence}
      end
    end
  end

  def evidence_digest(_evidence), do: {:error, :invalid_settlement_evidence}

  @spec build_settlement_receipt(map()) :: {:ok, settlement_receipt()} | {:error, term()}
  def build_settlement_receipt(input) when is_map(input) do
    with {:ok, finding_key} <- fetch_finding_key(input),
         {:ok, finding_lineage_key} <- fetch_lineage_key(input),
         {:ok, evaluation_key} <- fetch_evaluation_key(input),
         {:ok, resolve_attempt_key} <- fetch_resolve_attempt_key(input),
         :ok <- matching_identity_stack(finding_key, finding_lineage_key, evaluation_key, resolve_attempt_key),
         {:ok, disposition} <- required_disposition(input),
         {:ok, settled_head_sha} <- required_sha(input, :settled_head_sha),
         :ok <- matching_settled_head(evaluation_key, settled_head_sha),
         {:ok, operation_ids} <- required_operation_ids(input),
         {:ok, native_resources} <- required_native_resources(input),
         {:ok, evidence} <- required_map(input, :evidence),
         {:ok, evidence_sha256} <- evidence_digest(evidence),
         :ok <- matching_supplied_evidence_digest(input, evidence_sha256) do
      published_head_sha = optional_sha(input, :published_head_sha)

      digest =
        digest(:symphony_settlement_receipt_v1, {
          finding_key.digest,
          finding_lineage_key.digest,
          evaluation_key.digest,
          resolve_attempt_key.digest,
          disposition,
          evaluation_key.source_head_sha,
          evaluation_key.evaluated_head_sha,
          evaluation_key.current_head_sha,
          published_head_sha,
          settled_head_sha,
          canonical_operation_ids(operation_ids),
          canonical_native_resources(native_resources),
          evidence_sha256
        })

      {:ok,
       %{
         finding_key: finding_key,
         finding_lineage_key: finding_lineage_key,
         evaluation_key: evaluation_key,
         resolve_attempt_key: resolve_attempt_key,
         disposition: disposition,
         source_head_sha: evaluation_key.source_head_sha,
         evaluated_head_sha: evaluation_key.evaluated_head_sha,
         current_head_sha: evaluation_key.current_head_sha,
         published_head_sha: published_head_sha,
         settled_head_sha: settled_head_sha,
         operation_ids: operation_ids,
         native_resources: native_resources,
         evidence: evidence,
         evidence_sha256: evidence_sha256,
         digest: digest
       }}
    end
  end

  def build_settlement_receipt(_input), do: {:error, :invalid_settlement_receipt_input}

  @spec reconcile_receipt(map()) :: {:ok, settlement_receipt()} | {:error, term()}
  def reconcile_receipt(input) when is_map(input) do
    case fetch_original_receipt(input) do
      {:ok, original} ->
        with {:ok, rebuilt} <- build_settlement_receipt(original),
             true <- rebuilt == original do
          {:ok, rebuilt}
        else
          false -> {:error, :terminal_receipt_evidence_unavailable}
          {:error, _reason} -> {:error, :terminal_receipt_evidence_unavailable}
        end

      {:error, _reason} ->
        {:error, :terminal_receipt_evidence_unavailable}
    end
  end

  def reconcile_receipt(_input), do: {:error, :terminal_receipt_evidence_unavailable}

  @spec exact_head(atom(), evaluation_key() | settlement_receipt(), String.t()) ::
          :ok | {:error, term()}
  def exact_head(:source, %{source_head_sha: expected}, actual) when is_binary(actual) do
    if expected == actual, do: :ok, else: {:error, :source_head_mismatch}
  end

  def exact_head(:evaluated, %{evaluated_head_sha: expected}, actual) when is_binary(actual) do
    if expected == actual, do: :ok, else: {:error, :evaluated_head_mismatch}
  end

  def exact_head(:current, %{current_head_sha: expected}, actual) when is_binary(actual) do
    if expected == actual, do: :ok, else: {:error, :current_head_mismatch}
  end

  def exact_head(:published, %{published_head_sha: expected}, actual)
      when is_binary(expected) and is_binary(actual) do
    if expected == actual, do: :ok, else: {:error, :published_head_mismatch}
  end

  def exact_head(:settled, %{settled_head_sha: expected}, actual) when is_binary(actual) do
    if expected == actual, do: :ok, else: {:error, :settled_head_mismatch}
  end

  def exact_head(_lifecycle, _identity, _actual), do: {:error, :exact_head_unverified}

  @spec resolve_operation_identity(resolve_attempt_key()) :: {:ok, String.t()} | {:error, term()}
  def resolve_operation_identity(%{digest: digest}) when is_binary(digest) do
    {:ok, digest(:symphony_operation_identity_v2, {:github_review_thread_resolve, digest})}
  end

  def resolve_operation_identity(_key), do: {:error, :invalid_resolve_operation_identity}

  defp fetch_finding_key(input) do
    case Map.get(input, :finding_key) || Map.get(input, "finding_key") do
      %{} = key ->
        with {:ok, rebuilt} <- build_finding_key(key),
             true <- rebuilt.digest == key[:digest] || rebuilt.digest == key["digest"] || is_nil(key[:digest]) do
          {:ok, rebuilt}
        else
          false -> {:error, :non_canonical_finding_key}
          {:error, reason} -> {:error, reason}
        end

      _missing ->
        build_finding_key(input)
    end
  end

  defp fetch_lineage_key(input) do
    case Map.get(input, :finding_lineage_key) || Map.get(input, "finding_lineage_key") ||
           Map.get(input, :lineage_key) do
      %{} = key ->
        with {:ok, rebuilt} <- build_lineage_key(key) do
          {:ok, rebuilt}
        end

      _missing ->
        build_lineage_key(input)
    end
  end

  defp fetch_evaluation_key(input) do
    case Map.get(input, :evaluation_key) || Map.get(input, "evaluation_key") do
      %{} = key ->
        with {:ok, finding_key} <- fetch_finding_key(key),
             {:ok, rebuilt} <- build_evaluation_key(Map.put(key, :finding_key, finding_key)) do
          {:ok, rebuilt}
        end

      _missing ->
        build_evaluation_key(input)
    end
  end

  defp fetch_resolve_attempt_key(input) do
    case Map.get(input, :resolve_attempt_key) || Map.get(input, "resolve_attempt_key") do
      %{} = key ->
        with {:ok, evaluation_key} <- fetch_evaluation_key(key),
             {:ok, rebuilt} <-
               build_resolve_attempt_key(Map.merge(key, %{evaluation_key: evaluation_key})) do
          {:ok, rebuilt}
        end

      _missing ->
        build_resolve_attempt_key(input)
    end
  end

  defp fetch_reopen_epoch(input) do
    case optional_digest(input, :reopen_epoch) do
      epoch when is_binary(epoch) -> {:ok, epoch}
      nil -> derive_reopen_epoch(input)
    end
  end

  defp fetch_original_receipt(input) do
    original =
      Map.get(input, :original_receipt) ||
        Map.get(input, "original_receipt") ||
        Map.get(input, :native_resource)

    if is_map(original), do: {:ok, original}, else: {:error, :terminal_receipt_evidence_unavailable}
  end

  defp matching_identity_stack(finding_key, lineage_key, evaluation_key, resolve_attempt_key) do
    cond do
      evaluation_key.finding_key.digest != finding_key.digest ->
        {:error, :evaluation_finding_mismatch}

      lineage_key.repository != finding_key.repository or
        lineage_key.pull_request_number != finding_key.pull_request_number or
          lineage_key.review_thread_id != finding_key.review_thread_id ->
        {:error, :lineage_scope_mismatch}

      resolve_attempt_key.evaluation_key.digest != evaluation_key.digest ->
        {:error, :resolve_attempt_evaluation_mismatch}

      true ->
        :ok
    end
  end

  defp matching_observed_head(
         {_repository, _pull_request_number, _review_thread_id, _thread_state, observed_head_sha, _node_id},
         evaluation_key
       ) do
    if observed_head_sha == evaluation_key.current_head_sha do
      :ok
    else
      {:error, :native_thread_state_unverified}
    end
  end

  defp matching_native_thread_state(
         {_repository, _pull_request_number, _review_thread_id, native_state, _observed_head_sha, _node_id},
         thread_state
       ) do
    if native_state == thread_state, do: :ok, else: {:error, :native_thread_state_unverified}
  end

  defp optional_native_node_id(readback) do
    value = Map.get(readback, :node_id) || Map.get(readback, "node_id")
    if is_binary(value) and String.trim(value) != "", do: value, else: nil
  end

  defp matching_settled_head(evaluation_key, settled_head_sha) do
    if evaluation_key.current_head_sha == settled_head_sha and
         evaluation_key.evaluated_head_sha == settled_head_sha do
      :ok
    else
      {:error, :settled_head_not_current_evaluation}
    end
  end

  defp matching_supplied_evidence_digest(input, evidence_sha256) do
    supplied = Map.get(input, :evidence_sha256) || Map.get(input, "evidence_sha256")

    cond do
      is_nil(supplied) -> :ok
      supplied == evidence_sha256 -> :ok
      true -> {:error, :evidence_digest_mismatch}
    end
  end

  defp required_native_thread_readback(input, evaluation_key) do
    readback = Map.get(input, :native_thread) || Map.get(input, "native_thread")

    with %{} <- readback || :missing,
         {:ok, repository} <- required_string(readback, :repository),
         {:ok, pull_request_number} <- required_positive_integer(readback, :pull_request_number),
         {:ok, review_thread_id} <- required_string(readback, :review_thread_id),
         {:ok, thread_state} <- required_thread_state(readback),
         {:ok, observed_head_sha} <- required_sha(readback, :observed_head_sha),
         true <- repository == evaluation_key.finding_key.repository,
         true <- pull_request_number == evaluation_key.finding_key.pull_request_number,
         true <- review_thread_id == evaluation_key.finding_key.review_thread_id do
      {:ok, {repository, pull_request_number, review_thread_id, thread_state, observed_head_sha, optional_native_node_id(readback)}}
    else
      :missing -> {:error, :native_thread_state_unverified}
      false -> {:error, :native_thread_state_unverified}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_thread_state(input) do
    case Map.get(input, :thread_state) || Map.get(input, "thread_state") do
      state when state in @thread_states -> {:ok, state}
      _invalid -> {:error, :native_thread_state_unverified}
    end
  end

  defp required_operation_ids(input) do
    ids = Map.get(input, :operation_ids) || Map.get(input, "operation_ids")

    if is_map(ids) and map_size(ids) > 0 and Enum.all?(ids, fn {_k, v} -> digest?(v) end) do
      {:ok, ids}
    else
      {:error, :settlement_operation_ids_unverified}
    end
  end

  defp required_native_resources(input) do
    resources = Map.get(input, :native_resources) || Map.get(input, "native_resources")

    if is_map(resources) and map_size(resources) > 0 do
      {:ok, resources}
    else
      {:error, :settlement_native_resources_unverified}
    end
  end

  defp required_disposition(input) do
    case Map.get(input, :disposition) || Map.get(input, "disposition") do
      disposition when disposition in @dispositions -> {:ok, disposition}
      _invalid -> {:error, :unsupported_settlement_disposition}
    end
  end

  defp required_map(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if is_map(value), do: {:ok, value}, else: {:error, {:missing_field, key}}
  end

  defp required_atom(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if is_atom(value) and not is_nil(value), do: {:ok, value}, else: {:error, {:missing_field, key}}
  end

  defp required_boolean(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if is_boolean(value), do: {:ok, value}, else: {:error, {:missing_field, key}}
  end

  defp required_string(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, {:missing_field, key}}
    end
  end

  defp required_positive_integer(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:missing_field, key}}
    end
  end

  defp required_sha(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    if is_binary(value) and Regex.match?(@sha_re, value) do
      {:ok, value}
    else
      {:error, {:invalid_sha, key}}
    end
  end

  defp required_digest(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    if digest?(value) do
      {:ok, value}
    else
      {:error, {:invalid_digest, key}}
    end
  end

  defp optional_sha(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    cond do
      is_nil(value) -> nil
      is_binary(value) and Regex.match?(@sha_re, value) -> value
      true -> nil
    end
  end

  defp optional_digest(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if digest?(value), do: value, else: nil
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_re, value)

  defp canonical_operation_ids(ids) do
    ids
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort()
  end

  defp canonical_native_resources(resources) do
    resources
    |> Enum.map(fn {key, value} -> {to_string(key), inspect(value, custom_options: [])} end)
    |> Enum.sort()
  end

  defp digest(tag, value) do
    :crypto.hash(:sha256, :erlang.term_to_binary({tag, value}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
