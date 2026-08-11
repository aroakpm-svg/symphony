defmodule SymphonyElixir.PatchAuthorization do
  @moduledoc """
  Design 3's single authorization boundary.

  The module is intentionally fail-closed while the Design 2 owner contract is unavailable. It
  does not recreate Design 2 identity, ledger, or publish behavior.
  """

  @type authorization_input :: map()
  @type authorization_evidence :: map()
  @type effect_scope :: map()
  @type authorization_dependencies :: map()

  @spec authorize(
          authorization_input(),
          [term()],
          authorization_evidence(),
          effect_scope(),
          authorization_dependencies()
        ) :: {:blocked, term()} | {:ok, map()} | {:authorization_required, map()} | {:reconcile, map()}
  def authorize(input, ledger_entries, evidence, effect_scope, dependencies)
      when is_map(input) and is_list(ledger_entries) and is_map(evidence) and is_map(effect_scope) and
             is_map(dependencies) do
    with :ok <- validate_design2_contract(dependencies),
         :ok <- validate_input(input, effect_scope),
         {:ok, finding_keys} <- finding_keys(input),
         :ok <- validate_design2_digest(dependencies.design2, finding_keys) do
      _ = ledger_entries
      _ = evidence
      {:blocked, :authorization_projection_unimplemented}
    else
      {:error, reason} -> {:blocked, reason}
    end
  end

  def authorize(_input, _ledger_entries, _evidence, _effect_scope, _dependencies),
    do: {:blocked, :invalid_authorization_input}

  defp validate_design2_contract(%{design2: design2}) when is_atom(design2) do
    if Code.ensure_loaded?(design2) and function_exported?(design2, :finding_set_digest, 1) do
      :ok
    else
      {:error, :design2_contract_unavailable}
    end
  end

  defp validate_design2_contract(_dependencies), do: {:error, :design2_contract_unavailable}

  defp validate_input(input, effect_scope) do
    with :ok <- validate_profile(input),
         :ok <- validate_repository(input),
         :ok <- validate_pull_request_number(input),
         :ok <- validate_evaluated_head(input),
         :ok <- validate_claim_scope(input, effect_scope),
         :ok <- validate_findings(input) do
      :ok
    end
  end

  defp validate_profile(%{profile: :aroak_autonomous_v1}), do: :ok
  defp validate_profile(%{profile: profile}), do: {:error, {:invalid_profile, profile}}
  defp validate_profile(_input), do: {:error, :missing_profile}

  defp validate_repository(%{repository: repository})
       when is_binary(repository) and byte_size(repository) > 0,
       do: :ok

  defp validate_repository(_input), do: {:error, :invalid_repository}

  defp validate_pull_request_number(%{pull_request_number: number})
       when is_integer(number) and number > 0,
       do: :ok

  defp validate_pull_request_number(_input), do: {:error, :invalid_pull_request_number}

  defp validate_evaluated_head(%{evaluated_head_sha: head}) when is_binary(head) do
    if valid_head_sha?(head), do: :ok, else: {:error, :invalid_evaluated_head_sha}
  end

  defp validate_evaluated_head(_input), do: {:error, :invalid_evaluated_head_sha}

  defp validate_claim_scope(input, %{claim_context: claim_context}) when is_map(claim_context) do
    repository_matches? = claim_context[:repository] == input[:repository]
    pull_request_matches? = claim_context[:pull_request_number] == input[:pull_request_number]

    if repository_matches? and pull_request_matches?, do: :ok, else: {:error, :claim_scope_mismatch}
  end

  defp validate_claim_scope(_input, _effect_scope), do: {:error, :claim_scope_unavailable}

  defp validate_findings(%{eligible_findings: findings, evaluated_head_sha: evaluated_head})
       when is_list(findings) and findings != [] do
    Enum.reduce_while(findings, MapSet.new(), fn finding, finding_keys ->
      if is_map(finding) do
        with {:ok, finding_key} <- Map.fetch(finding, :finding_key),
             :ok <- validate_finding_disposition(finding),
             :ok <- validate_finding_head(finding, evaluated_head) do
          if MapSet.member?(finding_keys, finding_key) do
            {:halt, {:error, :duplicate_finding_key}}
          else
            {:cont, MapSet.put(finding_keys, finding_key)}
          end
        else
          :error -> {:halt, {:error, :missing_finding_key}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:halt, {:error, :invalid_finding_shape}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_findings(_input), do: {:error, :missing_eligible_findings}

  defp validate_finding_disposition(%{disposition: :fix_in_current_pr}), do: :ok

  defp validate_finding_disposition(%{disposition: disposition}),
    do: {:error, {:invalid_finding_disposition, disposition}}

  defp validate_finding_disposition(_finding), do: {:error, :missing_finding_disposition}

  defp validate_finding_head(
         %{evaluated_head_sha: finding_head, source_head_sha: source_head},
         evaluated_head
       )
       when is_binary(finding_head) and is_binary(source_head) and is_binary(evaluated_head) do
    cond do
      finding_head != evaluated_head -> {:error, :finding_evaluated_head_mismatch}
      not valid_head_sha?(finding_head) -> {:error, :invalid_finding_evaluated_head_sha}
      not valid_head_sha?(source_head) -> {:error, :invalid_finding_source_head_sha}
      finding_head != source_head -> {:error, :finding_source_head_mismatch}
      true -> :ok
    end
  end

  defp validate_finding_head(_finding, _evaluated_head), do: {:error, :invalid_finding_head_evidence}

  defp finding_keys(%{eligible_findings: findings}) do
    {:ok, Enum.map(findings, &Map.fetch!(&1, :finding_key))}
  rescue
    KeyError -> {:error, :missing_finding_key}
  end

  defp validate_design2_digest(design2, finding_keys) do
    case design2.finding_set_digest(finding_keys) do
      {:ok, digest} when is_binary(digest) and byte_size(digest) > 0 -> :ok
      _ -> {:error, :design2_finding_set_digest_unavailable}
    end
  rescue
    _error -> {:error, :design2_finding_set_digest_unavailable}
  end

  defp valid_head_sha?(head), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, head)
end
