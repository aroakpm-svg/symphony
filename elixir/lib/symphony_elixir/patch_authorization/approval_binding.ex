defmodule SymphonyElixir.PatchAuthorization.ApprovalBinding do
  @moduledoc false

  @approval_command "批准再修一輪"

  @spec bind(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def bind(request, approval, evidence)
      when is_map(request) and is_map(approval) and is_map(evidence) do
    with :ok <- validate_request(request),
         :ok <- validate_evidence(evidence),
         :ok <- validate_snapshot(request, evidence),
         :ok <- validate_command(approval),
         {:ok, actor_id} <- verified_actor_id(approval),
         :ok <- validate_authority(evidence),
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

  def bind(_request, _approval, _evidence), do: {:error, :invalid_approval_evidence}

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
         is_struct(evidence[:used_comment_ids], MapSet) do
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

  defp verified_actor_id(approval) do
    actor_id = approval[:actor] |> actor_id()

    if non_empty_string?(actor_id), do: {:ok, actor_id}, else: {:error, :authorization_actor_unknown}
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(actor) when is_map(actor), do: Map.get(actor, :id) || Map.get(actor, "id")
  defp actor_id(_actor), do: nil

  defp validate_authority(%{authority_result: :authorized}), do: :ok
  defp validate_authority(%{authority_result: :unauthorized}), do: {:error, :unauthorized_actor}
  defp validate_authority(_evidence), do: {:error, :authorization_policy_unavailable}

  defp validate_unused_comment(approval, evidence) do
    if MapSet.member?(evidence[:used_comment_ids], approval[:comment_id]) do
      {:error, :approval_comment_already_used}
    else
      :ok
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
