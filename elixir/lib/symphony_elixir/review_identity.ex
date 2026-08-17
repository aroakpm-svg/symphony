defmodule SymphonyElixir.ReviewIdentity do
  @moduledoc """
  Canonical identity algebra for Design 2/4 settlement.

  FindingKey identifies a review finding without head. Heads live on
  EvaluationKey. Resolve attempts include a durable/native-derived
  reopen epoch. Settlement receipts are append-only and immutable.

  `build_resolve_attempt_key/1` always derives `reopen_epoch` from native
  thread state. Rebuilding a persisted nested `resolve_attempt_key` only
  checks the stored epoch digest: reconcile has no attempt-time native
  thread, so it cannot re-derive.
  """

  @sha_re ~r/\A[0-9a-f]{40}\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/
  @dispositions [:fix_in_current_pr, :follow_up_required, :rejected]
  @thread_states [:resolved, :unresolved]
  @native_roles [:reply, :resolve, :follow_up, :publish]
  @receipt_fields [
    :finding_key,
    :finding_lineage_key,
    :evaluation_key,
    :resolve_attempt_key,
    :disposition,
    :source_head_sha,
    :evaluated_head_sha,
    :current_head_sha,
    :published_head_sha,
    :settled_head_sha,
    :operation_ids,
    :native_resources,
    :native_readbacks,
    :evidence,
    :evidence_sha256,
    :digest
  ]

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
          native_readbacks: map(),
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
         :ok <- matching_native_thread_state(native_readback, thread_state),
         {:ok, prior} <- fetch_prior_resolve_operation_id(input) do
      reopen_epoch_from(thread_state, prior, evaluation_key, native_readback)
    end
  end

  def derive_reopen_epoch(_input), do: {:error, :invalid_reopen_epoch_input}

  defp reopen_epoch_from(:unresolved, nil, evaluation_key, _native_readback) do
    {:ok, digest(:symphony_reopen_epoch_v1, {:initial, evaluation_key.digest})}
  end

  defp reopen_epoch_from(:unresolved, prior, _evaluation_key, native_readback) when is_binary(prior) do
    {:ok, digest(:symphony_reopen_epoch_v1, {:reopened, prior, native_readback})}
  end

  defp reopen_epoch_from(:resolved, prior, evaluation_key, _native_readback) when is_binary(prior) do
    {:ok, digest(:symphony_reopen_epoch_v1, {:same_cycle, prior, evaluation_key.digest})}
  end

  defp reopen_epoch_from(:resolved, nil, _evaluation_key, _native_readback) do
    {:error, :resolved_without_prior_resolve}
  end

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

  @spec project_native_paths(map()) :: {:ok, map()} | {:error, term()}
  def project_native_paths(paths) when is_map(paths) and map_size(paths) > 0 do
    Enum.reduce_while(paths, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      collect_native_path(acc, key, value)
    end)
  end

  def project_native_paths(_paths), do: {:error, :settlement_native_resources_unverified}

  @spec evidence_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def evidence_digest(evidence) when is_map(evidence) do
    case terminal_evidence_tuple(evidence) do
      {:ok, payload} -> {:ok, digest(:symphony_settlement_evidence_v2, payload)}
      {:error, _reason} -> {:error, :invalid_settlement_evidence}
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
         {:ok, native_resources} <- required_projected_paths(input, :native_resources),
         {:ok, native_readbacks} <- required_projected_paths(input, :native_readbacks),
         :ok <- matching_native_projections(native_resources, native_readbacks),
         {:ok, evidence} <- required_map(input, :evidence),
         {:ok, terminal_evidence} <-
           assemble_terminal_evidence(%{
             finding_key: finding_key,
             finding_lineage_key: finding_lineage_key,
             evaluation_key: evaluation_key,
             resolve_attempt_key: resolve_attempt_key,
             disposition: disposition,
             settled_head_sha: settled_head_sha,
             published_head_sha: optional_sha(input, :published_head_sha),
             operation_ids: operation_ids,
             native_resources: native_resources,
             native_readbacks: native_readbacks,
             evidence: evidence
           }),
         {:ok, evidence_sha256} <- evidence_digest(terminal_evidence),
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
          canonical_native_paths(native_resources),
          canonical_native_paths(native_readbacks),
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
         native_readbacks: native_readbacks,
         evidence: terminal_evidence,
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
             :ok <- matching_rebuilt_receipt(rebuilt, original) do
          {:ok, rebuilt}
        else
          {:error, _reason} -> {:error, :terminal_receipt_evidence_unavailable}
        end

      {:error, _reason} ->
        {:error, :terminal_receipt_evidence_unavailable}
    end
  end

  def reconcile_receipt(_input), do: {:error, :terminal_receipt_evidence_unavailable}

  @spec receipt_matches_settlement(map(), finding_key(), atom()) :: boolean()
  def receipt_matches_settlement(resource, finding_key, disposition)
      when is_map(resource) and is_map(finding_key) do
    case reconcile_receipt(%{original_receipt: resource}) do
      {:ok, rebuilt} ->
        rebuilt.finding_key.digest == finding_key.digest and rebuilt.disposition == disposition

      _invalid ->
        false
    end
  end

  def receipt_matches_settlement(_resource, _finding_key, _disposition), do: false

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
        case build_finding_key(key) do
          {:ok, rebuilt} -> accept_canonical_finding_key(rebuilt, key)
          {:error, reason} -> {:error, reason}
        end

      _missing ->
        build_finding_key(input)
    end
  end

  defp accept_canonical_finding_key(rebuilt, key) do
    supplied = Map.get(key, :digest) || Map.get(key, "digest")

    cond do
      is_nil(supplied) -> {:ok, rebuilt}
      supplied == rebuilt.digest -> {:ok, rebuilt}
      true -> {:error, :non_canonical_finding_key}
    end
  end

  defp fetch_lineage_key(input) do
    case Map.get(input, :finding_lineage_key) || Map.get(input, "finding_lineage_key") ||
           Map.get(input, :lineage_key) do
      %{} = key ->
        with {:ok, rebuilt} <- build_lineage_key(key) do
          accept_supplied_digest(rebuilt, key, :non_canonical_finding_lineage_key)
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
          accept_supplied_digest(rebuilt, key, :non_canonical_evaluation_key)
        end

      _missing ->
        build_evaluation_key(input)
    end
  end

  defp fetch_resolve_attempt_key(input) do
    case Map.get(input, :resolve_attempt_key) || Map.get(input, "resolve_attempt_key") do
      %{} = key ->
        rebuild_canonical_resolve_attempt_key(key)

      _missing ->
        build_resolve_attempt_key(input)
    end
  end

  defp rebuild_canonical_resolve_attempt_key(key) do
    with {:ok, evaluation_key} <- fetch_evaluation_key(key),
         {:ok, reopen_epoch} <- required_digest_field(key, :reopen_epoch) do
      rebuilt = %{
        evaluation_key: evaluation_key,
        reopen_epoch: reopen_epoch,
        digest: digest(:symphony_resolve_attempt_v1, {evaluation_key.digest, reopen_epoch})
      }

      accept_supplied_digest(rebuilt, key, :non_canonical_resolve_attempt_key)
    end
  end

  defp required_digest_field(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if digest?(value), do: {:ok, value}, else: {:error, {:invalid_digest, key}}
  end

  defp fetch_reopen_epoch(input) do
    with {:ok, derived} <- derive_reopen_epoch(input) do
      case fetch_optional_digest_field(input, :reopen_epoch) do
        :absent -> {:ok, derived}
        {:ok, ^derived} -> {:ok, derived}
        {:ok, _other} -> {:error, :reopen_epoch_mismatch}
        :invalid -> {:error, :reopen_epoch_mismatch}
      end
    end
  end

  defp fetch_prior_resolve_operation_id(input) do
    case fetch_optional_digest_field(input, :prior_resolve_operation_id) do
      :absent -> {:ok, nil}
      {:ok, digest} -> {:ok, digest}
      :invalid -> {:error, :invalid_prior_resolve_operation_id}
    end
  end

  defp accept_supplied_digest(rebuilt, key, error) do
    supplied = Map.get(key, :digest) || Map.get(key, "digest")

    cond do
      is_nil(supplied) -> {:ok, rebuilt}
      supplied == rebuilt.digest -> {:ok, rebuilt}
      true -> {:error, error}
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

  defp matching_rebuilt_receipt(rebuilt, original) do
    with :ok <- known_receipt_fields(original),
         :ok <- compare_receipt_fields(rebuilt, original) do
      :ok
    else
      _invalid -> {:error, :terminal_receipt_evidence_unavailable}
    end
  end

  defp known_receipt_fields(original) do
    allowed = MapSet.new(Enum.flat_map(@receipt_fields, &[&1, Atom.to_string(&1)]))

    if Enum.all?(Map.keys(original), &MapSet.member?(allowed, &1)) do
      :ok
    else
      :error
    end
  end

  defp compare_receipt_fields(rebuilt, original) do
    Enum.reduce_while(@receipt_fields, :ok, fn field, :ok ->
      if values_match?(Map.get(rebuilt, field), receipt_field(original, field)) do
        {:cont, :ok}
      else
        {:halt, :error}
      end
    end)
  end

  defp receipt_field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp receipt_field(map, key) when is_map(map), do: Map.get(map, key)

  defp values_match?(left, right) do
    cond do
      left == right ->
        true

      is_atom(left) and is_binary(right) ->
        Atom.to_string(left) == right

      is_map(left) and is_map(right) ->
        Enum.all?(left, fn {key, value} ->
          values_match?(value, receipt_field(right, key))
        end) and compatible_map_size?(left, right)

      true ->
        false
    end
  end

  defp compatible_map_size?(left, right) do
    map_size(left) == map_size(right)
  end

  defp collect_native_path(acc, key, value) do
    role = normalize_native_role(key)

    cond do
      role not in @native_roles -> {:halt, {:error, {:unknown_native_path, key}}}
      Map.has_key?(acc, role) -> {:halt, {:error, {:duplicate_native_path, role}}}
      true -> put_projected_path(acc, role, value)
    end
  end

  defp put_projected_path(acc, role, value) do
    case project_native_path(role, value) do
      {:ok, projected} -> {:cont, {:ok, Map.put(acc, role, projected)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp assemble_terminal_evidence(parts) do
    evidence = parts.evidence

    with {:ok, status} <- required_atom(evidence, :status),
         {:ok, reopened?} <- required_false(evidence, :reopened?),
         {:ok, newer_actionable?} <- required_false(evidence, :newer_actionable?) do
      {:ok,
       %{
         finding_key_digest: parts.finding_key.digest,
         finding_lineage_key_digest: parts.finding_lineage_key.digest,
         evaluation_key_digest: parts.evaluation_key.digest,
         resolve_attempt_key_digest: parts.resolve_attempt_key.digest,
         disposition: parts.disposition,
         status: status,
         claim_id: parts.evaluation_key.claim_id,
         generation: parts.evaluation_key.generation,
         source_head_sha: parts.evaluation_key.source_head_sha,
         evaluated_head_sha: parts.evaluation_key.evaluated_head_sha,
         current_head_sha: parts.evaluation_key.current_head_sha,
         published_head_sha: parts.published_head_sha,
         settled_head_sha: parts.settled_head_sha,
         operation_ids: Map.new(canonical_operation_ids(parts.operation_ids)),
         native_resources: parts.native_resources,
         native_readbacks: parts.native_readbacks,
         reopened?: reopened?,
         newer_actionable?: newer_actionable?
       }}
    end
  end

  defp terminal_evidence_tuple(evidence) do
    with {:ok, finding_key_digest} <- required_digest(evidence, :finding_key_digest),
         {:ok, finding_lineage_key_digest} <- required_digest(evidence, :finding_lineage_key_digest),
         {:ok, evaluation_key_digest} <- required_digest(evidence, :evaluation_key_digest),
         {:ok, resolve_attempt_key_digest} <- required_digest(evidence, :resolve_attempt_key_digest),
         {:ok, disposition} <- required_disposition(evidence),
         {:ok, status} <- required_atom(evidence, :status),
         {:ok, claim_id} <- required_string(evidence, :claim_id),
         {:ok, generation} <- required_positive_integer(evidence, :generation),
         {:ok, source_head_sha} <- required_sha(evidence, :source_head_sha),
         {:ok, evaluated_head_sha} <- required_sha(evidence, :evaluated_head_sha),
         {:ok, current_head_sha} <- required_sha(evidence, :current_head_sha),
         {:ok, settled_head_sha} <- required_sha(evidence, :settled_head_sha),
         {:ok, operation_ids} <- required_operation_ids(evidence),
         {:ok, native_resources} <- required_projected_paths(evidence, :native_resources),
         {:ok, native_readbacks} <- required_projected_paths(evidence, :native_readbacks),
         :ok <- matching_native_projections(native_resources, native_readbacks),
         {:ok, reopened?} <- required_false(evidence, :reopened?),
         {:ok, newer_actionable?} <- required_false(evidence, :newer_actionable?) do
      published_head_sha = optional_sha(evidence, :published_head_sha)

      {:ok,
       {
         finding_key_digest,
         finding_lineage_key_digest,
         evaluation_key_digest,
         resolve_attempt_key_digest,
         disposition,
         status,
         claim_id,
         generation,
         source_head_sha,
         evaluated_head_sha,
         current_head_sha,
         published_head_sha,
         settled_head_sha,
         canonical_operation_ids(operation_ids),
         canonical_native_paths(native_resources),
         canonical_native_paths(native_readbacks),
         reopened?,
         newer_actionable?
       }}
    end
  end

  defp native_observation(
         repository,
         pull_request_number,
         review_thread_id,
         thread_state,
         observed_head_sha,
         readback
       ) do
    node_id = optional_native_node_id(readback)

    {repository, pull_request_number, review_thread_id, thread_state, observed_head_sha, node_id}
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
         :ok <- matching_native_thread_identity(repository, pull_request_number, review_thread_id, evaluation_key) do
      {:ok,
       native_observation(
         repository,
         pull_request_number,
         review_thread_id,
         thread_state,
         observed_head_sha,
         readback
       )}
    else
      :missing -> {:error, :native_thread_state_unverified}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_native_thread_identity(repository, pull_request_number, review_thread_id, evaluation_key) do
    finding = evaluation_key.finding_key

    if repository == finding.repository and pull_request_number == finding.pull_request_number and
         review_thread_id == finding.review_thread_id do
      :ok
    else
      {:error, :native_thread_state_unverified}
    end
  end

  defp required_thread_state(input) do
    case known_atom(Map.get(input, :thread_state) || Map.get(input, "thread_state"), @thread_states) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :native_thread_state_unverified}
    end
  end

  defp required_projected_paths(input, key) do
    case Map.get(input, key) || Map.get(input, Atom.to_string(key)) do
      paths when is_map(paths) -> project_native_paths(paths)
      _missing -> {:error, :settlement_native_resources_unverified}
    end
  end

  defp matching_native_projections(resources, readbacks) do
    if resources == readbacks do
      :ok
    else
      {:error, :settlement_native_resource_mismatch}
    end
  end

  defp normalize_native_role(role) when role in @native_roles, do: role
  defp normalize_native_role("reply"), do: :reply
  defp normalize_native_role("resolve"), do: :resolve
  defp normalize_native_role("follow_up"), do: :follow_up
  defp normalize_native_role("publish"), do: :publish
  defp normalize_native_role(_role), do: :unknown

  defp project_native_path(:reply, value) when is_map(value) do
    with {:ok, comment_id} <- required_string(value, :comment_id),
         {:ok, repository} <- required_string(value, :repository),
         {:ok, pull_request_number} <- required_positive_integer(value, :pull_request_number),
         {:ok, thread_id} <- required_string(value, :thread_id),
         {:ok, body_sha256} <- required_digest(value, :body_sha256),
         {:ok, head_sha} <- required_sha(value, :head_sha) do
      {:ok,
       %{
         comment_id: comment_id,
         repository: repository,
         pull_request_number: pull_request_number,
         thread_id: thread_id,
         body_sha256: body_sha256,
         head_sha: head_sha
       }}
    else
      {:error, _reason} -> {:error, {:invalid_native_path, :reply}}
    end
  end

  defp project_native_path(:resolve, value) when is_map(value) do
    with {:ok, review_thread_id} <- required_string(value, :review_thread_id),
         {:ok, repository} <- required_string(value, :repository),
         {:ok, pull_request_number} <- required_positive_integer(value, :pull_request_number),
         {:ok, resolved} <- required_boolean(value, :resolved),
         {:ok, observed_head_sha} <- required_sha(value, :observed_head_sha) do
      {:ok,
       %{
         review_thread_id: review_thread_id,
         repository: repository,
         pull_request_number: pull_request_number,
         resolved: resolved,
         observed_head_sha: observed_head_sha
       }}
    else
      {:error, _reason} -> {:error, {:invalid_native_path, :resolve}}
    end
  end

  defp project_native_path(:follow_up, value) when is_map(value) do
    with {:ok, issue_id} <- required_string(value, :issue_id),
         {:ok, identifier} <- required_string(value, :identifier),
         {:ok, destination} <- required_string(value, :destination),
         {:ok, state} <- required_string(value, :state),
         {:ok, lineage_digest} <- required_digest(value, :lineage_digest) do
      {:ok,
       %{
         issue_id: issue_id,
         identifier: identifier,
         destination: destination,
         state: state,
         lineage_digest: lineage_digest
       }}
    else
      {:error, _reason} -> {:error, {:invalid_native_path, :follow_up}}
    end
  end

  defp project_native_path(:publish, value) when is_map(value) do
    with {:ok, commit_sha} <- required_sha(value, :commit_sha),
         {:ok, tree_sha} <- required_sha(value, :tree_sha),
         {:ok, repository} <- required_string(value, :repository),
         {:ok, pull_request_number} <- required_positive_integer(value, :pull_request_number) do
      {:ok,
       %{
         commit_sha: commit_sha,
         tree_sha: tree_sha,
         repository: repository,
         pull_request_number: pull_request_number
       }}
    else
      {:error, _reason} -> {:error, {:invalid_native_path, :publish}}
    end
  end

  defp project_native_path(role, _value), do: {:error, {:invalid_native_path, role}}

  defp required_operation_ids(input) do
    ids = Map.get(input, :operation_ids) || Map.get(input, "operation_ids")

    if is_map(ids) and map_size(ids) > 0 and Enum.all?(ids, fn {_k, v} -> digest?(v) end) do
      {:ok, ids}
    else
      {:error, :settlement_operation_ids_unverified}
    end
  end

  defp required_disposition(input) do
    case known_atom(Map.get(input, :disposition) || Map.get(input, "disposition"), @dispositions) do
      {:ok, disposition} -> {:ok, disposition}
      :error -> {:error, :unsupported_settlement_disposition}
    end
  end

  defp required_map(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))
    if is_map(value), do: {:ok, value}, else: {:error, {:missing_field, key}}
  end

  defp required_atom(input, key) do
    case existing_atom(fetch_field(input, key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp known_atom(value, allowed) do
    cond do
      value in allowed ->
        {:ok, value}

      is_binary(value) ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> :error
          atom -> {:ok, atom}
        end

      true ->
        :error
    end
  end

  defp existing_atom(value) when is_atom(value) and not is_nil(value), do: {:ok, value}

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(_value), do: :error

  defp required_boolean(input, key) do
    value = fetch_field(input, key)
    if is_boolean(value), do: {:ok, value}, else: {:error, {:missing_field, key}}
  end

  defp required_false(input, key) do
    case fetch_field(input, key) do
      false -> {:ok, false}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_field(input, key) do
    cond do
      Map.has_key?(input, key) ->
        Map.get(input, key)

      Map.has_key?(input, Atom.to_string(key)) ->
        Map.get(input, Atom.to_string(key))

      true ->
        nil
    end
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

  defp fetch_optional_digest_field(input, key) do
    cond do
      Map.has_key?(input, key) ->
        classify_optional_digest(Map.get(input, key))

      Map.has_key?(input, Atom.to_string(key)) ->
        classify_optional_digest(Map.get(input, Atom.to_string(key)))

      true ->
        :absent
    end
  end

  defp classify_optional_digest(nil), do: :absent
  defp classify_optional_digest(value), do: if(digest?(value), do: {:ok, value}, else: :invalid)

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_re, value)

  defp canonical_operation_ids(ids) do
    ids
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort()
  end

  defp canonical_native_paths(paths) do
    paths
    |> Enum.map(fn {role, projected} -> {role, native_path_tuple(role, projected)} end)
    |> Enum.sort()
  end

  defp native_path_tuple(:reply, projected) do
    {
      projected.comment_id,
      projected.repository,
      projected.pull_request_number,
      projected.thread_id,
      projected.body_sha256,
      projected.head_sha
    }
  end

  defp native_path_tuple(:resolve, projected) do
    {
      projected.review_thread_id,
      projected.repository,
      projected.pull_request_number,
      projected.resolved,
      projected.observed_head_sha
    }
  end

  defp native_path_tuple(:follow_up, projected) do
    {projected.issue_id, projected.identifier, projected.destination, projected.state, projected.lineage_digest}
  end

  defp native_path_tuple(:publish, projected) do
    {projected.commit_sha, projected.tree_sha, projected.repository, projected.pull_request_number}
  end

  defp digest(tag, value) do
    :crypto.hash(:sha256, :erlang.term_to_binary({tag, value}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
