defmodule SymphonyElixir.HandoffReceipt do
  @moduledoc """
  Defines the remotely verifiable ARO-166 handoff receipt contract.

  A receipt is a hint. Fresh native evidence, claim fencing, and the effect
  ledger remain authoritative for every mutation.
  """

  alias SymphonyElixir.HandoffReceipt.Store

  @checkpoint_kinds ~w(pushed pull_request reviewed)a
  @receipt_keys MapSet.new(~w(
    receipt_schema_version issue_id repository claim_id generation
    checkpoint_sequence recorded_at checkpoint_kind branch head_sha
    tested_head_sha pr_number test_results effect_operation_ids
  )a)
  @observation_keys MapSet.new(~w(
    issue_id repository branch remote_head_sha pr_number pr_head_sha git_ready?
    linear_current? active_claim? exact_head_review_passed? effect_statuses
  )a)
  @sha_pattern ~r/^[0-9a-f]{40}$/
  @repository_pattern ~r/^[a-z0-9_.-]+\/[a-z0-9_.-]+$/

  @type checkpoint_kind :: :pushed | :pull_request | :reviewed
  @type test_result :: %{name: String.t(), status: :passed | :skipped}
  @type effect_status :: :succeeded | :pending | :failed_no_effect | :unknown
  @type receipt :: %{
          receipt_schema_version: 1,
          issue_id: String.t(),
          repository: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          checkpoint_sequence: pos_integer(),
          recorded_at: DateTime.t(),
          checkpoint_kind: checkpoint_kind(),
          branch: String.t(),
          head_sha: String.t(),
          tested_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          test_results: [test_result()],
          effect_operation_ids: [String.t()]
        }
  @type observation :: %{
          issue_id: String.t(),
          repository: String.t(),
          branch: String.t(),
          remote_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          pr_head_sha: String.t() | nil,
          git_ready?: boolean(),
          linear_current?: boolean(),
          active_claim?: boolean(),
          exact_head_review_passed?: boolean(),
          effect_statuses: %{optional(String.t()) => effect_status()}
        }

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(receipt) when is_map(receipt) do
    with :ok <- exact_keys(receipt, @receipt_keys, :receipt_shape),
         :ok <- exact_value(receipt.receipt_schema_version, 1, :schema_version),
         :ok <- non_empty(receipt.issue_id, :issue_id),
         :ok <- repository(receipt.repository),
         :ok <- uuid(receipt.claim_id, :claim_id),
         :ok <- positive(receipt.generation, :generation),
         :ok <- positive(receipt.checkpoint_sequence, :checkpoint_sequence),
         :ok <- recorded_at(receipt.recorded_at),
         :ok <- checkpoint_kind(receipt.checkpoint_kind),
         :ok <- non_empty(receipt.branch, :branch),
         :ok <- sha(receipt.head_sha, :head_sha),
         :ok <- tested_sha(receipt.tested_head_sha, receipt.head_sha),
         :ok <- pr_number(receipt.checkpoint_kind, receipt.pr_number),
         :ok <- test_results(receipt.test_results),
         :ok <- effect_operation_ids(receipt.effect_operation_ids) do
      :ok
    end
  end

  def validate(_receipt), do: {:error, :receipt_shape}

  @spec append(Postgrex.conn(), Store.claim_context(), Store.append_attrs()) ::
          {:ok, receipt()} | {:error, term()}
  def append(connection, claim, attrs), do: Store.append(connection, claim, attrs)

  @spec latest(Postgrex.conn(), Store.claim_context()) ::
          {:ok, receipt() | nil} | {:error, term()}
  def latest(connection, claim), do: Store.latest(connection, claim)

  @spec resume(receipt() | nil, observation()) ::
          {:ok, :pull_request | :review | :complete} | {:safe_recheck, atom()}
  def resume(nil, _observation), do: {:safe_recheck, :receipt_missing}

  def resume(receipt, observation) do
    with :ok <- compatible_receipt(receipt),
         :ok <- compatible_observation(observation),
         :ok <- matching_identity(receipt, observation),
         :ok <- required_flag(observation.active_claim?, :claim_inactive),
         :ok <- required_flag(observation.linear_current?, :linear_changed),
         :ok <- required_flag(observation.git_ready?, :git_unready),
         :ok <- equal(observation.remote_head_sha, receipt.head_sha, :remote_head_changed),
         :ok <- matching_pull_request(receipt, observation),
         :ok <- matching_review(receipt, observation),
         :ok <- settled_effects(receipt, observation),
         :ok <- native_state_not_advanced(receipt, observation) do
      next_action(receipt.checkpoint_kind)
    else
      {:error, reason} -> {:safe_recheck, reason}
    end
  end

  defp exact_keys(map, expected, reason),
    do: if(MapSet.new(Map.keys(map)) == expected, do: :ok, else: {:error, reason})

  defp exact_value(value, value, _reason), do: :ok
  defp exact_value(_actual, _expected, reason), do: {:error, reason}

  defp non_empty(value, reason) when is_binary(value) do
    if String.trim(value) == "", do: {:error, reason}, else: :ok
  end

  defp non_empty(_value, reason), do: {:error, reason}

  defp positive(value, _reason) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, reason), do: {:error, reason}

  defp uuid(value, _reason) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :claim_id}
    end
  end

  defp uuid(_value, reason), do: {:error, reason}

  defp recorded_at(%DateTime{}), do: :ok
  defp recorded_at(_value), do: {:error, :recorded_at}

  defp checkpoint_kind(kind) when kind in @checkpoint_kinds, do: :ok
  defp checkpoint_kind(_kind), do: {:error, :checkpoint_kind}

  defp repository(value) when is_binary(value) do
    if Regex.match?(@repository_pattern, value), do: :ok, else: {:error, :repository}
  end

  defp repository(_value), do: {:error, :repository}

  defp sha(value, reason) when is_binary(value) do
    if Regex.match?(@sha_pattern, value), do: :ok, else: {:error, reason}
  end

  defp sha(_value, reason), do: {:error, reason}

  defp tested_sha(value, head_sha) when value == head_sha, do: sha(value, :tested_head_sha)
  defp tested_sha(_value, _head_sha), do: {:error, :tested_head_sha}

  defp pr_number(:pushed, nil), do: :ok

  defp pr_number(kind, value)
       when kind in [:pull_request, :reviewed] and is_integer(value) and value > 0,
       do: :ok

  defp pr_number(_kind, _value), do: {:error, :pr_number}

  defp test_results(results) when is_list(results) and results != [] do
    if Enum.all?(results, &valid_test_result?/1), do: :ok, else: {:error, :test_results}
  end

  defp test_results(_results), do: {:error, :test_results}

  defp valid_test_result?(result) when is_map(result) do
    MapSet.new(Map.keys(result)) == MapSet.new([:name, :status]) and
      is_binary(result.name) and String.trim(result.name) != "" and
      result.status in [:passed, :skipped]
  end

  defp valid_test_result?(_result), do: false

  defp effect_operation_ids(ids) when is_list(ids) do
    valid = Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != ""))

    if valid and length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, :effect_operation_ids}
  end

  defp effect_operation_ids(_ids), do: {:error, :effect_operation_ids}

  defp compatible_receipt(receipt) do
    case validate(receipt) do
      :ok -> :ok
      {:error, _reason} -> {:error, :receipt_incompatible}
    end
  end

  defp compatible_observation(observation) when is_map(observation) do
    result =
      with :ok <- exact_keys(observation, @observation_keys, :observation_incompatible),
           :ok <- non_empty(observation.issue_id, :issue_id),
           :ok <- repository(observation.repository),
           :ok <- non_empty(observation.branch, :branch),
           :ok <- sha(observation.remote_head_sha, :remote_head_sha),
           :ok <- optional_positive(observation.pr_number),
           :ok <- optional_sha(observation.pr_head_sha),
           :ok <- booleans(observation),
           :ok <- effect_statuses(observation.effect_statuses) do
        :ok
      end

    case result do
      :ok -> :ok
      {:error, _reason} -> {:error, :observation_incompatible}
    end
  end

  defp compatible_observation(_observation), do: {:error, :observation_incompatible}

  defp optional_positive(nil), do: :ok
  defp optional_positive(value) when is_integer(value) and value > 0, do: :ok
  defp optional_positive(_value), do: {:error, :pr_number}

  defp optional_sha(nil), do: :ok
  defp optional_sha(value), do: sha(value, :pr_head_sha)

  defp booleans(observation) do
    values = [
      observation.git_ready?,
      observation.linear_current?,
      observation.active_claim?,
      observation.exact_head_review_passed?
    ]

    if Enum.all?(values, &is_boolean/1), do: :ok, else: {:error, :boolean_flag}
  end

  defp effect_statuses(statuses) when is_map(statuses) do
    valid =
      Enum.all?(statuses, fn {operation_id, status} ->
        is_binary(operation_id) and String.trim(operation_id) != "" and
          status in [:succeeded, :pending, :failed_no_effect, :unknown]
      end)

    if valid, do: :ok, else: {:error, :effect_statuses}
  end

  defp effect_statuses(_statuses), do: {:error, :effect_statuses}

  defp matching_identity(receipt, observation) do
    stored = {receipt.issue_id, receipt.repository, receipt.branch}
    native = {observation.issue_id, observation.repository, observation.branch}

    if stored == native, do: :ok, else: {:error, :identity_changed}
  end

  defp required_flag(true, _reason), do: :ok
  defp required_flag(false, reason), do: {:error, reason}

  defp equal(value, value, _reason), do: :ok
  defp equal(_actual, _expected, reason), do: {:error, reason}

  defp matching_pull_request(%{checkpoint_kind: :pushed}, _observation), do: :ok

  defp matching_pull_request(receipt, observation) do
    if observation.pr_number == receipt.pr_number and observation.pr_head_sha == receipt.head_sha,
      do: :ok,
      else: {:error, :pull_request_changed}
  end

  defp matching_review(%{checkpoint_kind: :reviewed}, %{exact_head_review_passed?: true}), do: :ok
  defp matching_review(%{checkpoint_kind: :reviewed}, _observation), do: {:error, :review_stale}
  defp matching_review(_receipt, _observation), do: :ok

  defp settled_effects(receipt, observation) do
    expected = MapSet.new(receipt.effect_operation_ids)
    observed = MapSet.new(Map.keys(observation.effect_statuses))

    if expected == observed and
         Enum.all?(observation.effect_statuses, fn {_id, status} -> status == :succeeded end),
       do: :ok,
       else: {:error, :effect_unsettled}
  end

  defp native_state_not_advanced(%{checkpoint_kind: :pushed}, observation) do
    if is_nil(observation.pr_number) and is_nil(observation.pr_head_sha) and
         not observation.exact_head_review_passed?,
       do: :ok,
       else: {:error, :native_state_advanced}
  end

  defp native_state_not_advanced(%{checkpoint_kind: :pull_request}, observation) do
    if observation.exact_head_review_passed?,
      do: {:error, :native_state_advanced},
      else: :ok
  end

  defp native_state_not_advanced(%{checkpoint_kind: :reviewed}, _observation), do: :ok

  defp next_action(:pushed), do: {:ok, :pull_request}
  defp next_action(:pull_request), do: {:ok, :review}
  defp next_action(:reviewed), do: {:ok, :complete}
end
