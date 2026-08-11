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
         :ok <- validate_approval_provenance(request, approval),
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
         non_empty_string?(request[:repository]) and
         is_integer(request[:pull_request_number]) and request[:pull_request_number] > 0 and
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

  defp validate_approval_provenance(request, approval) do
    provenance = approval[:provenance]

    if plain_map?(provenance) do
      with {:ok, status} <-
             required_field(
               provenance,
               :status,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           :ok <- validate_provenance_status(status),
           {:ok, request_id} <-
             required_field(
               provenance,
               :request_id,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           {:ok, repository} <-
             required_field(
               provenance,
               :repository,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           {:ok, pull_request_number} <-
             required_field(
               provenance,
               :pull_request_number,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           {:ok, head_sha} <-
             required_field(
               provenance,
               :head_sha,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           {:ok, finding_set_digest} <-
             required_field(
               provenance,
               :finding_set_digest,
               :authorization_provenance_unknown,
               :authorization_provenance_conflict
             ),
           :ok <-
             validate_provenance_values(
               request_id,
               repository,
               pull_request_number,
               head_sha,
               finding_set_digest
             ) do
        compare_approval_provenance(
          request,
          request_id,
          repository,
          pull_request_number,
          head_sha,
          finding_set_digest
        )
      end
    else
      {:error, :authorization_provenance_unknown}
    end
  end

  defp validate_provenance_status(:verified), do: :ok
  defp validate_provenance_status(_status), do: {:error, :authorization_provenance_unknown}

  defp validate_provenance_values(
         request_id,
         repository,
         pull_request_number,
         head_sha,
         finding_set_digest
       ) do
    if non_empty_string?(request_id) and
         non_empty_string?(repository) and
         is_integer(pull_request_number) and pull_request_number > 0 and
         non_empty_string?(head_sha) and
         non_empty_string?(finding_set_digest) do
      :ok
    else
      {:error, :authorization_provenance_unknown}
    end
  end

  defp compare_approval_provenance(
         request,
         request_id,
         repository,
         pull_request_number,
         head_sha,
         finding_set_digest
       ) do
    if request_id == request[:request_id] and
         repository == request[:repository] and
         pull_request_number == request[:pull_request_number] and
         head_sha == request[:evaluated_head_sha] and
         finding_set_digest == request[:eligible_finding_set_digest] do
      :ok
    else
      {:error, :authorization_request_mismatch}
    end
  end

  defp verified_actor_id(approval) do
    verify_actor_map(approval[:actor])
  end

  defp verify_actor_map(%{__struct__: _}), do: {:error, :authorization_actor_unknown}

  defp verify_actor_map(actor) when is_map(actor) do
    with {:ok, actor_id} <-
           required_field(actor, :id, :authorization_actor_unknown, :authorization_actor_conflict),
         {:ok, actor_type} <-
           required_field(actor, :type, :authorization_actor_unknown, :authorization_actor_conflict) do
      cond do
        not non_empty_string?(actor_id) ->
          {:error, :authorization_actor_unknown}

        actor_type != "User" ->
          {:error, :non_human_actor}

        true ->
          {:ok, actor_id}
      end
    end
  end

  defp verify_actor_map(_actor), do: {:error, :authorization_actor_unknown}

  defp validate_authority(evidence, actor_id) do
    authority_result = evidence[:authority_result]

    if plain_map?(authority_result) do
      validate_authority_result(authority_result, actor_id)
    else
      {:error, :authorization_policy_unavailable}
    end
  end

  defp validate_authority_result(%{status: :authorized} = result, actor_id) do
    case required_field(result, :actor_id, :authorization_actor_unknown, :authorization_actor_conflict) do
      {:ok, authority_actor_id} ->
        cond do
          not non_empty_string?(authority_actor_id) ->
            {:error, :authorization_actor_unknown}

          authority_actor_id != actor_id ->
            {:error, :authorization_actor_mismatch}

          true ->
            :ok
        end

      {:error, reason} ->
        {:error, reason}
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

  defp required_field(map, key, missing_reason, conflict_reason) do
    case consistent_field(map, key, conflict_reason) do
      {:ok, nil} -> {:error, missing_reason}
      {:ok, value} -> {:ok, value}
      :missing -> {:error, missing_reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consistent_field(map, key, conflict_reason) do
    string_key = Atom.to_string(key)

    case {Map.fetch(map, key), Map.fetch(map, string_key)} do
      {{:ok, atom_value}, {:ok, string_value}} when atom_value == string_value ->
        {:ok, atom_value}

      {{:ok, _atom_value}, {:ok, _string_value}} ->
        {:error, conflict_reason}

      {{:ok, value}, :error} ->
        {:ok, value}

      {:error, {:ok, value}} ->
        {:ok, value}

      {:error, :error} ->
        :missing
    end
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
