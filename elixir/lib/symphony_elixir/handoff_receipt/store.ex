defmodule SymphonyElixir.HandoffReceipt.Store do
  @moduledoc """
  Persists and reads ARO-166 receipts through function-only PostgreSQL access.
  """

  alias SymphonyElixir.HandoffReceipt

  @append_sql """
  select receipt_schema_version, issue_id, repository, claim_id::text,
         generation, checkpoint_sequence, recorded_at, checkpoint_kind,
         branch, head_sha, tested_head_sha, pr_number, test_results,
         effect_operation_ids
  from symphony_staging.append_handoff_receipt(
    $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid,
    $6, $7, $8, $9, $10, $11, $12::jsonb
  )
  """

  @latest_sql """
  select receipt_schema_version, issue_id, repository, claim_id::text,
         generation, checkpoint_sequence, recorded_at, checkpoint_kind,
         branch, head_sha, tested_head_sha, pr_number, test_results,
         effect_operation_ids
  from symphony_staging.latest_handoff_receipt(
    $1, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid
  )
  """

  @type claim_context :: %{
          issue_id: String.t(),
          claim_id: String.t(),
          generation: pos_integer(),
          node_id: String.t(),
          node_instance_id: String.t()
        }
  @type append_attrs :: %{
          repository: String.t(),
          checkpoint_kind: HandoffReceipt.checkpoint_kind(),
          branch: String.t(),
          head_sha: String.t(),
          tested_head_sha: String.t(),
          pr_number: pos_integer() | nil,
          test_results: [HandoffReceipt.test_result()]
        }

  @spec append(Postgrex.conn(), claim_context(), append_attrs()) ::
          {:ok, HandoffReceipt.receipt()} | {:error, term()}
  def append(connection, claim, attrs) do
    params = [
      claim.issue_id,
      claim.claim_id,
      claim.generation,
      claim.node_id,
      claim.node_instance_id,
      attrs.repository,
      Atom.to_string(attrs.checkpoint_kind),
      attrs.branch,
      attrs.head_sha,
      attrs.tested_head_sha,
      attrs.pr_number,
      encode_test_results(attrs.test_results)
    ]

    connection
    |> run_query(@append_sql, params)
    |> one_receipt()
  end

  @spec latest(Postgrex.conn(), claim_context()) ::
          {:ok, HandoffReceipt.receipt() | nil} | {:error, term()}
  def latest(connection, claim) do
    params = [claim.issue_id, claim.claim_id, claim.generation, claim.node_id, claim.node_instance_id]

    connection
    |> run_query(@latest_sql, params)
    |> optional_receipt()
  end

  defp run_query(connection, sql, params) do
    query = if is_function(connection, 2), do: connection, else: &Postgrex.query(connection, &1, &2)
    query.(sql, params)
  end

  defp one_receipt({:ok, %Postgrex.Result{rows: [row], num_rows: 1}}), do: decode_row(row)

  defp one_receipt({:ok, %Postgrex.Result{num_rows: count}}),
    do: {:error, {:unexpected_append_result, count}}

  defp one_receipt({:error, reason}), do: {:error, reason}

  defp optional_receipt({:ok, %Postgrex.Result{rows: [], num_rows: 0}}), do: {:ok, nil}
  defp optional_receipt({:ok, %Postgrex.Result{rows: [row], num_rows: 1}}), do: decode_row(row)

  defp optional_receipt({:ok, %Postgrex.Result{num_rows: count}}),
    do: {:error, {:unexpected_latest_result, count}}

  defp optional_receipt({:error, reason}), do: {:error, reason}

  defp decode_row([
         version,
         issue_id,
         repository,
         claim_id,
         generation,
         sequence,
         recorded_at,
         kind,
         branch,
         head_sha,
         tested_head_sha,
         pr_number,
         test_results,
         effect_operation_ids
       ]) do
    with {:ok, checkpoint_kind} <- decode_kind(kind),
         {:ok, decoded_tests} <- decode_test_results(test_results) do
      receipt = %{
        receipt_schema_version: version,
        issue_id: issue_id,
        repository: repository,
        claim_id: claim_id,
        generation: generation,
        checkpoint_sequence: sequence,
        recorded_at: recorded_at,
        checkpoint_kind: checkpoint_kind,
        branch: branch,
        head_sha: head_sha,
        tested_head_sha: tested_head_sha,
        pr_number: pr_number,
        test_results: decoded_tests,
        effect_operation_ids: effect_operation_ids
      }

      case HandoffReceipt.validate(receipt) do
        :ok -> {:ok, receipt}
        {:error, reason} -> {:error, {:incompatible_receipt, reason}}
      end
    else
      {:error, reason} -> {:error, {:incompatible_receipt, reason}}
    end
  end

  defp decode_row(_row), do: {:error, {:incompatible_receipt, :receipt_shape}}

  defp decode_kind("pushed"), do: {:ok, :pushed}
  defp decode_kind("pull_request"), do: {:ok, :pull_request}
  defp decode_kind("reviewed"), do: {:ok, :reviewed}
  defp decode_kind(_kind), do: {:error, :checkpoint_kind}

  defp encode_test_results(results) do
    Enum.map(results, fn %{name: name, status: status} ->
      %{"name" => name, "status" => Atom.to_string(status)}
    end)
  end

  defp decode_test_results(results) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      %{"name" => name, "status" => status} = item, {:ok, decoded}
      when map_size(item) == 2 and status in ["passed", "skipped"] ->
        {:cont, {:ok, [%{name: name, status: String.to_existing_atom(status)} | decoded]}}

      _item, _decoded ->
        {:halt, {:error, :test_results}}
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end)
  end

  defp decode_test_results(_results), do: {:error, :test_results}
end
