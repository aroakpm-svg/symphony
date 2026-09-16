defmodule SymphonyElixir.DispatchPolicy do
  @moduledoc """
  Evaluates an already-fetched dispatch authorization snapshot without side effects.
  """

  @type reason_code ::
          :invalid_input
          | :wrong_team
          | :wrong_project
          | :wrong_repository
          | :missing_worker_label
          | :inactive_state
          | :unowned_in_progress
          | :evidence_unavailable
          | :blocker_not_accepted
          | :human_gate_pending
          | :policy_revision_mismatch
          | :quota_exhausted
          | :paused
          | :unsupported_model

  @type decision :: %{
          issue_id: String.t(),
          policy_revision: term(),
          workflow_sha: String.t(),
          evidence_version: term(),
          evidence_valid_until: DateTime.t()
        }

  @reason_order [
    :invalid_input,
    :wrong_team,
    :wrong_project,
    :wrong_repository,
    :missing_worker_label,
    :inactive_state,
    :unowned_in_progress,
    :evidence_unavailable,
    :blocker_not_accepted,
    :human_gate_pending,
    :policy_revision_mismatch,
    :quota_exhausted,
    :paused,
    :unsupported_model
  ]

  @spec evaluate(term(), term(), term(), term(), term()) ::
          {:allow, decision()} | {:deny, [reason_code(), ...]}
  def evaluate(issue, policy, run_state, evidence, %DateTime{} = now)
      when is_map(issue) and is_map(policy) and is_map(run_state) and is_map(evidence) do
    if valid_datetime?(now) do
      evidence_usable? = evidence_usable?(policy, evidence, now)
      reason_flags = reason_flags(issue, policy, run_state, evidence, evidence_usable?)

      reasons = Enum.filter(@reason_order, &Map.fetch!(reason_flags, &1))

      case reasons do
        [] -> {:allow, receipt(issue, policy, evidence)}
        [_ | _] -> {:deny, reasons}
      end
    else
      {:deny, [:invalid_input]}
    end
  end

  def evaluate(_issue, _policy, _run_state, _evidence, _now),
    do: {:deny, [:invalid_input]}

  defp reason_flags(issue, policy, run_state, evidence, evidence_usable?) do
    scope = map_value(policy, :scope)

    %{
      invalid_input: not valid_nested_inputs?(issue, policy),
      wrong_team: map_value(issue, :team_id) != map_value(scope, :team_id),
      wrong_project: map_value(issue, :project_id) != map_value(scope, :project_id),
      wrong_repository: map_value(issue, :repository) != map_value(scope, :repository),
      missing_worker_label: not list_member?(map_value(issue, :label_ids), map_value(policy, :worker_label_id)),
      inactive_state: not list_member?(map_value(policy, :allowed_state_ids), map_value(issue, :state_id)),
      unowned_in_progress: unowned_in_progress?(issue, policy, run_state),
      evidence_unavailable: not evidence_usable?,
      blocker_not_accepted: blocker_not_accepted?(issue, evidence, evidence_usable?),
      human_gate_pending: human_gate_pending_reason?(policy, evidence, evidence_usable?),
      policy_revision_mismatch: policy_revision_mismatch?(issue, policy, run_state, evidence, evidence_usable?),
      quota_exhausted: quota_exhausted?(issue, policy, run_state),
      paused: map_value(run_state, :pause_state) != :active,
      unsupported_model: unsupported_model_reason?(policy, evidence, evidence_usable?)
    }
  end

  defp valid_nested_inputs?(issue, policy) do
    valid_issue_structure?(issue) and valid_policy_structure?(policy)
  end

  defp valid_issue_structure?(issue) do
    non_empty_binary?(map_value(issue, :id)) and
      non_empty_binary?(map_value(issue, :revision)) and
      non_empty_binary?(map_value(issue, :repository)) and
      binary_list?(map_value(issue, :label_ids))
  end

  defp valid_policy_structure?(policy) do
    scope = map_value(policy, :scope)

    valid_policy_identity?(policy) and valid_policy_lists?(policy) and
      valid_policy_controls?(policy) and valid_scope?(scope)
  end

  defp valid_policy_identity?(policy) do
    Map.has_key?(policy, :revision) and not is_nil(map_value(policy, :revision)) and
      non_empty_binary?(map_value(policy, :workflow_sha)) and
      non_empty_binary?(map_value(policy, :model)) and
      non_empty_binary?(map_value(policy, :worker_label_id))
  end

  defp valid_policy_lists?(policy) do
    binary_list?(map_value(policy, :allowed_state_ids)) and
      binary_list?(map_value(policy, :in_progress_state_ids))
  end

  defp valid_policy_controls?(policy) do
    map_value(policy, :human_gate) in [:required, :disabled] and
      is_map(map_value(policy, :limits))
  end

  defp valid_scope?(scope) do
    is_map(scope) and
      non_empty_binary?(map_value(scope, :team_id)) and
      non_empty_binary?(map_value(scope, :project_id)) and
      non_empty_binary?(map_value(scope, :repository))
  end

  defp evidence_usable?(policy, evidence, now) do
    read_at = map_value(evidence, :read_at)
    ttl_seconds = map_value(policy, :evidence_ttl_seconds)

    valid_evidence_shape?(evidence) and valid_evidence_time?(read_at, ttl_seconds, now)
  end

  defp valid_evidence_shape?(evidence) do
    map_value(evidence, :status) == :ok and
      map_value(evidence, :blockers_complete) == true and
      Map.has_key?(evidence, :version) and not is_nil(map_value(evidence, :version)) and
      is_map(map_value(evidence, :blocker_acceptance)) and
      binary_list?(map_value(evidence, :supported_models))
  end

  defp valid_evidence_time?(read_at, ttl_seconds, now) do
    is_integer(ttl_seconds) and ttl_seconds > 0 and
      valid_datetime_fields?(read_at) and
      DateTime.compare(read_at, now) != :gt and
      DateTime.compare(now, DateTime.add(read_at, ttl_seconds, :second)) != :gt
  rescue
    _exception -> false
  end

  defp valid_datetime?(%DateTime{} = datetime) do
    valid_datetime_fields?(datetime)
  rescue
    _exception -> false
  end

  defp valid_datetime_fields?(datetime) do
    DateTime.compare(datetime, datetime) == :eq and
      match?(%DateTime{}, DateTime.add(datetime, 0, :second))
  end

  defp unowned_in_progress?(issue, policy, run_state) do
    if list_member?(map_value(policy, :in_progress_state_ids), map_value(issue, :state_id)) do
      not valid_claim?(map_value(run_state, :claim), map_value(issue, :id))
    else
      false
    end
  end

  defp valid_claim?(%{issue_id: issue_id, generation: generation, active: true}, issue_id)
       when is_integer(generation) and generation > 0,
       do: true

  defp valid_claim?(_claim, _issue_id), do: false

  defp blockers_accepted?(issue, evidence) do
    blockers = map_value(issue, :blocked_by)
    acceptance = map_value(evidence, :blocker_acceptance)

    is_list(blockers) and
      Enum.all?(blockers, fn
        %{id: id} when is_binary(id) and byte_size(id) > 0 ->
          Map.get(acceptance, id) == %{state: "Done", accepted: true}

        _invalid_blocker ->
          false
      end)
  end

  defp blocker_not_accepted?(_issue, _evidence, false), do: false
  defp blocker_not_accepted?(issue, evidence, true), do: not blockers_accepted?(issue, evidence)

  defp human_gate_pending?(policy, evidence) do
    map_value(policy, :human_gate) == :required and
      map_value(map_value(evidence, :human_gate), :status) != :approved
  end

  defp human_gate_pending_reason?(_policy, _evidence, false), do: false
  defp human_gate_pending_reason?(policy, evidence, true), do: human_gate_pending?(policy, evidence)

  defp gate_binding_mismatch?(issue, policy, evidence) do
    gate = map_value(evidence, :human_gate)

    map_value(policy, :human_gate) == :required and
      map_value(gate, :status) == :approved and
      (map_value(gate, :issue_revision) != map_value(issue, :revision) or
         map_value(gate, :policy_revision) != map_value(policy, :revision) or
         map_value(gate, :workflow_sha) != map_value(policy, :workflow_sha))
  end

  defp run_binding_mismatch?(issue, policy, run_state) do
    map_value(run_state, :approved_issue_revision) != map_value(issue, :revision) or
      map_value(run_state, :approved_policy_revision) != map_value(policy, :revision) or
      map_value(run_state, :approved_workflow_sha) != map_value(policy, :workflow_sha)
  end

  defp policy_revision_mismatch?(issue, policy, run_state, evidence, evidence_usable?) do
    run_binding_mismatch?(issue, policy, run_state) or
      gate_binding_mismatch_reason?(issue, policy, evidence, evidence_usable?)
  end

  defp gate_binding_mismatch_reason?(_issue, _policy, _evidence, false), do: false

  defp gate_binding_mismatch_reason?(issue, policy, evidence, true),
    do: gate_binding_mismatch?(issue, policy, evidence)

  defp quota_exhausted?(issue, policy, run_state) do
    limits = map_value(policy, :limits)

    if valid_quota_data?(limits, run_state) do
      map_value(run_state, :accumulated_minutes) >= map_value(limits, :max_minutes) or
        map_value(run_state, :turns) >= map_value(limits, :max_turns) or
        map_value(run_state, :failures) >= map_value(limits, :max_failures) or
        distinct_issue_count(run_state, issue) > map_value(limits, :max_issues_24h)
    else
      true
    end
  end

  defp valid_quota_data?(limits, run_state) do
    is_map(limits) and
      non_negative_number?(map_value(limits, :max_minutes)) and
      non_negative_number?(map_value(limits, :max_turns)) and
      non_negative_number?(map_value(limits, :max_failures)) and
      non_negative_integer?(map_value(limits, :max_issues_24h)) and
      non_negative_number?(map_value(run_state, :accumulated_minutes)) and
      non_negative_number?(map_value(run_state, :turns)) and
      non_negative_number?(map_value(run_state, :failures)) and
      binary_list?(map_value(run_state, :issue_ids_24h))
  end

  defp distinct_issue_count(run_state, issue) do
    run_state
    |> map_value(:issue_ids_24h)
    |> MapSet.new()
    |> MapSet.put(map_value(issue, :id))
    |> MapSet.size()
  end

  defp unsupported_model?(policy, evidence) do
    not list_member?(map_value(evidence, :supported_models), map_value(policy, :model))
  end

  defp unsupported_model_reason?(_policy, _evidence, false), do: false
  defp unsupported_model_reason?(policy, evidence, true), do: unsupported_model?(policy, evidence)

  defp receipt(issue, policy, evidence) do
    %{
      issue_id: map_value(issue, :id),
      policy_revision: map_value(policy, :revision),
      workflow_sha: map_value(policy, :workflow_sha),
      evidence_version: map_value(evidence, :version),
      evidence_valid_until:
        DateTime.add(
          map_value(evidence, :read_at),
          map_value(policy, :evidence_ttl_seconds),
          :second
        )
    }
  end

  defp list_member?(values, value) when is_list(values), do: value in values
  defp list_member?(_values, _value), do: false

  defp binary_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)
  defp non_empty_binary?(value), do: is_binary(value) and byte_size(value) > 0
  defp non_negative_number?(value), do: is_number(value) and value >= 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_not_a_map, _key), do: nil
end
