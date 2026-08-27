defmodule Arbor.Orchestrator.CrossAppContinuation.Envelope do
  @moduledoc false

  alias Arbor.Actions
  alias Arbor.Contracts.Persistence.Record

  @schema_version 1
  @envelope_keys Enum.sort(
                   ~w(schema_version continuation_id snapshot successor terminal commit claim_binding)
                 )
  @commit_keys Enum.sort(~w(operation_id task_id transition payload_sha256 idempotency_key))
  @lineage_key_regex ~r/\Axappc_[0-9a-f]{64}\z/
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @operation_id_regex ~r/\A[A-Za-z0-9._:-]+\z/
  @max_operation_id_bytes 256
  @max_commit_bytes 2_048
  @max_snapshot_bytes 778_240
  @max_successor_bytes 516_352
  @max_terminal_bytes 512

  @spec operation_id(term()) :: {:ok, String.t()} | {:error, :malformed_operation_id}
  def operation_id(value) when is_binary(value) do
    if byte_size(value) in 1..@max_operation_id_bytes and String.valid?(value) and
         not String.contains?(value, <<0>>) and Regex.match?(@operation_id_regex, value) do
      {:ok, value}
    else
      {:error, :malformed_operation_id}
    end
  end

  def operation_id(_value), do: {:error, :malformed_operation_id}

  @spec continuation_id(term()) :: {:ok, String.t()} | {:error, :malformed_state}
  def continuation_id(value) when is_binary(value) do
    if Regex.match?(@lineage_key_regex, value),
      do: {:ok, value},
      else: {:error, :malformed_state}
  end

  def continuation_id(_value), do: {:error, :malformed_state}

  @spec operation_receipt(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def operation_receipt(operation_id, task_id, continuation_id, transition, payload_sha256) do
    receipt = %{
      "operation_id" => operation_id,
      "task_id" => task_id,
      "transition" => transition,
      "payload_sha256" => payload_sha256
    }

    with {:ok, _operation_id} <- operation_id(operation_id),
         true <- valid_task_id?(task_id),
         {:ok, _continuation_id} <- continuation_id(continuation_id),
         true <- is_binary(transition) and transition != "",
         true <- valid_digest?(payload_sha256),
         {:ok, idempotency_key} <-
           Actions.coding_cross_app_continuation_digest(
             Map.put(receipt, "continuation_id", continuation_id)
           ) do
      {:ok, Map.put(receipt, "idempotency_key", idempotency_key)}
    else
      false -> {:error, :malformed_record}
      {:error, _reason} -> {:error, :malformed_record}
    end
  end

  @spec build(String.t(), map(), term(), term(), map(), map() | nil, pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def build(continuation_id, snapshot, successor, terminal, commit, claim_binding, max_data_bytes) do
    data = %{
      "schema_version" => @schema_version,
      "continuation_id" => continuation_id,
      "snapshot" => snapshot,
      "successor" => successor,
      "terminal" => terminal,
      "commit" => commit,
      "claim_binding" => claim_binding
    }

    with :ok <- bound_json(commit, @max_commit_bytes),
         :ok <- bound_json(snapshot, @max_snapshot_bytes),
         :ok <- bound_optional(successor, @max_successor_bytes),
         :ok <- bound_optional(terminal, @max_terminal_bytes),
         :ok <- bound_measured(data, max_data_bytes) do
      {:ok, data}
    end
  end

  @spec admit_record(term(), pos_integer()) ::
          {:ok, Record.t(), map()} | {:error, atom()}
  def admit_record(%Record{} = record, max_data_bytes)
      when is_integer(max_data_bytes) and max_data_bytes > 0 do
    with :ok <- validate_record_shell(record, max_data_bytes),
         {:ok, data} <- admit_data(record.data, record.key) do
      {:ok, record, data}
    end
  end

  def admit_record(_record, _max_data_bytes), do: {:error, :malformed_record}

  @spec redact_snapshot(map()) :: map()
  def redact_snapshot(snapshot) when is_map(snapshot) do
    case snapshot["claim"] do
      claim when is_map(claim) ->
        Map.put(snapshot, "claim", Map.delete(claim, "fence_token"))

      _other ->
        snapshot
    end
  end

  def redact_snapshot(snapshot), do: snapshot

  @spec public_envelope(String.t(), String.t(), map(), term(), term(), Record.t(), atom()) ::
          map()
  def public_envelope(
        continuation_id,
        operation_id,
        snapshot,
        successor,
        terminal,
        %Record{} = record,
        class
      ) do
    %{
      "continuation_id" => continuation_id,
      "operation_id" => operation_id,
      "snapshot" => snapshot,
      "successor" => successor,
      "terminal" => terminal,
      "durability" => %{
        "generation" => Integer.to_string(record.generation),
        "revision" => Integer.to_string(record.revision),
        "class" => Atom.to_string(class)
      }
    }
  end

  defp admit_data(data, key) do
    with :ok <- require_json_object(data),
         :ok <- exact_keys(data, @envelope_keys),
         :ok <- require_schema(data["schema_version"]),
         {:ok, continuation_id} <- continuation_id(data["continuation_id"]),
         true <- continuation_id == key,
         {:ok, snapshot} <- Actions.coding_cross_app_continuation_new(data["snapshot"]),
         {:ok, lineage_key} <- Actions.coding_cross_app_continuation_lineage_key(snapshot),
         true <- lineage_key == key,
         {:ok, derived} <- Actions.coding_cross_app_continuation_retained_effects(snapshot),
         true <- derived["successor"] === data["successor"],
         true <- derived["terminal"] === data["terminal"],
         :ok <- bound_json(snapshot, @max_snapshot_bytes),
         :ok <- bound_optional(data["successor"], @max_successor_bytes),
         :ok <- bound_optional(data["terminal"], @max_terminal_bytes),
         {:ok, commit} <-
           admit_receipt(
             data["commit"],
             snapshot["identities"]["task_id"],
             continuation_id,
             :any
           ),
         {:ok, claim_binding} <-
           admit_claim_binding(data["claim_binding"], snapshot, continuation_id) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "continuation_id" => continuation_id,
         "snapshot" => snapshot,
         "successor" => derived["successor"],
         "terminal" => derived["terminal"],
         "commit" => commit,
         "claim_binding" => claim_binding
       }}
    else
      false -> {:error, :malformed_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_receipt(receipt, task_id, continuation_id, expected_transition) do
    with :ok <- require_json_object(receipt),
         :ok <- exact_keys(receipt, @commit_keys),
         {:ok, expected} <-
           operation_receipt(
             receipt["operation_id"],
             receipt["task_id"],
             continuation_id,
             receipt["transition"],
             receipt["payload_sha256"]
           ),
         true <- receipt === expected,
         true <- receipt["task_id"] == task_id,
         true <-
           expected_transition == :any or receipt["transition"] == expected_transition,
         :ok <- bound_json(receipt, @max_commit_bytes) do
      {:ok, receipt}
    else
      false -> {:error, :malformed_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_claim_binding(nil, snapshot, _continuation_id) when is_map(snapshot) do
    if snapshot["status"] == "claimed" or is_map(snapshot["claim"]),
      do: {:error, :malformed_record},
      else: {:ok, nil}
  end

  defp admit_claim_binding(binding, snapshot, continuation_id)
       when is_map(binding) and is_map(snapshot) do
    with {:ok, binding} <-
           admit_receipt(
             binding,
             snapshot["identities"]["task_id"],
             continuation_id,
             "claim"
           ),
         true <- snapshot["status"] == "claimed" and is_map(snapshot["claim"]),
         true <- snapshot["claim"]["owner_id"] == snapshot["identities"]["principal_id"] do
      {:ok, binding}
    else
      false -> {:error, :malformed_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_claim_binding(_binding, _snapshot, _continuation_id),
    do: {:error, :malformed_record}

  defp valid_digest?(value) when is_binary(value), do: Regex.match?(@digest_regex, value)
  defp valid_digest?(_value), do: false

  defp validate_record_shell(%Record{} = record, max_data_bytes) do
    cond do
      not is_binary(record.id) or record.id == "" ->
        {:error, :malformed_record}

      record.metadata != %{} ->
        {:error, :malformed_record}

      not is_integer(record.generation) or record.generation < 1 ->
        {:error, :malformed_record}

      not is_integer(record.revision) or record.revision < 1 ->
        {:error, :malformed_record}

      true ->
        bound_measured(record.data, max_data_bytes)
    end
  end

  defp require_schema(@schema_version), do: :ok
  defp require_schema(_version), do: {:error, :malformed_record}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == keys, do: :ok, else: {:error, :malformed_record}
  end

  defp require_json_object(value) when is_map(value) and not is_struct(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_record}
  end

  defp require_json_object(_value), do: {:error, :malformed_record}

  defp valid_task_id?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= 256 and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defp valid_task_id?(_value), do: false

  defp bound_optional(nil, _max), do: :ok
  defp bound_optional(value, max), do: bound_json(value, max)

  defp bound_json(value, max) when is_integer(max) do
    bound_measured(value, max)
  end

  defp bound_measured(value, max) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max -> :ok
      {:ok, _encoded} -> {:error, :oversized_state}
      {:error, _reason} -> {:error, :malformed_record}
    end
  end

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp json_clean?(_value), do: false
end
