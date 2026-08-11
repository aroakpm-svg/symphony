defmodule SymphonyElixir.PatchAuthorization.ApprovalBinding do
  @moduledoc false

  @approval_command "批准再修一輪"

  @spec bind(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def bind(request, approval, evidence)
      when is_map(request) and is_map(approval) and is_map(evidence) do
    if Enum.all?([request, approval, evidence], &plain_map?/1) do
      bind_verified_evidence(request, approval, evidence)
    else
      {:error, :invalid_approval_evidence}
    end
  end

  def bind(_request, _approval, _evidence), do: {:error, :invalid_approval_evidence}

  defp bind_verified_evidence(request, approval, evidence) do
    with :ok <- validate_request(request),
         :ok <- validate_evidence(evidence),
         :ok <- validate_snapshot(request, evidence),
         :ok <- validate_command(approval),
         :ok <- validate_comment_id(approval),
         {:ok, actor_id} <- verified_actor_id(approval),
         :ok <- validate_authority(evidence, actor_id),
         :ok <- validate_unused_comment(approval, evidence) do
      {:ok,
       %{
         request_id: request[:request_id],
         comment_id: approval[:comment_id],
         actor_id: actor_id,
         authorization_identity: actor_id,
         slot: {:human, request[:request_id], approval[:comment_id], actor_id}
       }}
    end
  end

  defp validate_request(request) do
    if non_empty_string?(request[:request_id]) and
         non_empty_string?(request[:evaluated_head_sha]) and
         non_empty_string?(request[:eligible_finding_set_digest]) do
      :ok
    else
      {:error, :invalid_approval_evidence}
    end
  end

  defp validate_evidence(evidence) do
    if non_empty_string?(evidence[:current_head_sha]) and
         non_empty_string?(evidence[:current_finding_set_digest]) and
         valid_comment_ids?(evidence[:used_comment_ids]) do
      :ok
    else
      {:error, :invalid_approval_evidence}
    end
  end

  defp validate_snapshot(request, evidence) do
    cond do
      request[:evaluated_head_sha] != evidence[:current_head_sha] ->
        {:error, :authorization_request_stale}

      request[:eligible_finding_set_digest] != evidence[:current_finding_set_digest] ->
        {:error, :authorization_finding_set_changed}

      true ->
        :ok
    end
  end

  defp validate_command(approval) do
    if is_binary(approval[:body]) and String.trim(approval[:body]) == @approval_command do
      :ok
    else
      {:error, :invalid_authorization_command}
    end
  end

  defp validate_comment_id(approval) do
    if non_empty_string?(approval[:comment_id]) do
      :ok
    else
      {:error, :invalid_approval_evidence}
    end
  end

  defp verified_actor_id(approval) do
    actor = approval[:actor]
    actor_id = actor_id(actor)
    actor_type = actor_type(actor)

    cond do
      not plain_map?(actor) or not non_empty_string?(actor_id) or is_nil(actor_type) ->
        {:error, :authorization_actor_unknown}

      actor_type != "User" ->
        {:error, :non_human_actor}

      true ->
        {:ok, actor_id}
    end
  end

  defp actor_id(actor) when is_map(actor), do: Map.get(actor, :id) || Map.get(actor, "id")
  defp actor_id(_actor), do: nil

  defp actor_type(actor) when is_map(actor), do: Map.get(actor, :type) || Map.get(actor, "type")
  defp actor_type(_actor), do: nil

  defp validate_authority(evidence, actor_id) do
    authority_result = evidence[:authority_result]

    if plain_map?(authority_result) do
      validate_authority_result(authority_result, actor_id)
    else
      {:error, :authorization_policy_unavailable}
    end
  end

  defp validate_authority_result(%{status: :authorized} = result, actor_id) do
    authority_actor_id = Map.get(result, :actor_id) || Map.get(result, "actor_id")

    cond do
      not non_empty_string?(authority_actor_id) -> {:error, :authorization_actor_unknown}
      authority_actor_id != actor_id -> {:error, :authorization_actor_mismatch}
      true -> :ok
    end
  end

  defp validate_authority_result(%{status: :unauthorized}, _actor_id), do: {:error, :unauthorized_actor}
  defp validate_authority_result(_result, _actor_id), do: {:error, :authorization_policy_unavailable}

  defp validate_unused_comment(approval, evidence) do
    if MapSet.member?(evidence[:used_comment_ids], approval[:comment_id]) do
      {:error, :approval_comment_already_used}
    else
      :ok
    end
  end

  defp valid_comment_ids?(%MapSet{map: map}) when is_map(map), do: true
  defp valid_comment_ids?(_comment_ids), do: false

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
