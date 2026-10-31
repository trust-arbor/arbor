defmodule Arbor.Trust.ApprovalEvidenceCore do
  @moduledoc """
  Closed approval evidence admission and bounded deduplication.

  The ConfirmationTracker owns this volatile state alongside its counters.
  Full capacity refuses new evidence instead of evicting replay protection.
  No caller field can claim a verified human responder.
  """

  alias Arbor.Contracts.Security.CapabilityUri

  @scope_fields [:agent_id, :principal_id, :resource_uri, :decision]
  @record_fields [:source, :request_id | @scope_fields]
  @max_answers 10_000

  def new, do: %{}

  def validate_expected(source, request_id, expected) do
    with true <- source in [:interaction, :consensus],
         true <- valid_string?(request_id),
         true <- is_map(expected) and map_size(expected) == length(@scope_fields),
         true <- Enum.all?(@scope_fields, &Map.has_key?(expected, &1)),
         true <- valid_scope?(expected) do
      {:ok, Map.merge(expected, %{source: source, request_id: request_id})}
    else
      _ -> {:error, :invalid_approval_evidence}
    end
  end

  def validate_record(expected, record) when is_map(record) do
    if valid_responder?(record) and Map.drop(record, [:verified_human_id]) == expected,
      do: :ok,
      else: {:error, :approval_evidence_mismatch}
  end

  def validate_record(_expected, _record), do: {:error, :approval_evidence_mismatch}

  defp valid_responder?(record) do
    case Map.fetch(record, :verified_human_id) do
      :error ->
        map_size(record) == length(@record_fields)

      {:ok, human_id} ->
        map_size(record) == length(@record_fields) + 1 and valid_string?(human_id) and
          String.starts_with?(human_id, "human_")
    end
  end

  def admit(answers, record) do
    key = {record.source, record.request_id}

    case Map.fetch(answers, key) do
      {:ok, ^record} -> {:ok, :duplicate, answers}
      {:ok, _other} -> {:error, :approval_evidence_mismatch}
      :error when map_size(answers) >= @max_answers -> {:error, :confirmation_capacity}
      :error -> {:ok, :recorded, Map.put(answers, key, record)}
    end
  end

  defp valid_scope?(scope) do
    valid_string?(scope.agent_id) and valid_string?(scope.principal_id) and
      valid_string?(scope.resource_uri) and
      match?({:ok, _}, CapabilityUri.parse(scope.resource_uri)) and
      scope.decision in [:approve, :deny, :rework]
  end

  defp valid_string?(value) do
    is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end
end
