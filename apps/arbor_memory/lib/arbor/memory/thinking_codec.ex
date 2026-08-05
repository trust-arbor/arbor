defmodule Arbor.Memory.ThinkingCodec do
  @moduledoc false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @version 1
  # C0 permits 256 raw array items, but each thinking item expands into payload,
  # envelope, taint, and chain nodes. Ninety-six leaves headroom under C0's
  # 4,096-node ceiling even for a full valid taint chain; byte-heavy aggregates
  # are reduced further by Thinking's protected-head tail eviction.
  @max_entries 96
  @max_identifier_bytes 256
  @max_text_bytes 65_536
  @max_metadata_bytes 131_072
  @max_entry_bytes 262_144
  @max_aggregate_bytes 1_048_576

  @entry_keys [:agent_id, :created_at, :id, :metadata, :significant, :text]
  @payload_keys ~w(agent_id created_at id metadata significant text)
  @aggregate_keys ~w(entries version)
  @item_keys ~w(payload provenance)

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type decoded_item :: {map(), Taint.t(), provenance_status()}

  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @spec entry_payload(term()) :: {:ok, map()} | {:error, :invalid_payload}
  def entry_payload(entry) when is_map(entry) and not is_struct(entry) do
    with true <- exact_keys?(entry, @entry_keys),
         :ok <- validate_identifier(entry.id),
         :ok <- validate_identifier(entry.agent_id),
         :ok <- validate_text(entry.text),
         true <- is_boolean(entry.significant),
         true <- match?(%DateTime{}, entry.created_at),
         true <- plain_map?(entry.metadata),
         :ok <- bounded_external(entry.metadata, @max_metadata_bytes),
         payload <- %{
           "id" => entry.id,
           "agent_id" => entry.agent_id,
           "text" => entry.text,
           "significant" => entry.significant,
           "created_at" => DateTime.to_iso8601(entry.created_at),
           "metadata" => entry.metadata
         },
         :ok <- bounded_external(payload, @max_entry_bytes),
         {:ok, _canonical} <- TaintEnvelope.canonical_json(payload) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  def entry_payload(_entry), do: {:error, :invalid_payload}

  @spec entry_from_payload(term(), String.t()) :: {:ok, map()} | {:error, :invalid_payload}
  def entry_from_payload(payload, expected_agent_id)
      when is_map(payload) and not is_struct(payload) and is_binary(expected_agent_id) do
    with true <- exact_keys?(payload, @payload_keys),
         :ok <- validate_identifier(expected_agent_id),
         true <- payload["agent_id"] == expected_agent_id,
         :ok <- validate_identifier(payload["id"]),
         :ok <- validate_text(payload["text"]),
         true <- is_boolean(payload["significant"]),
         true <- plain_map?(payload["metadata"]),
         :ok <- bounded_external(payload["metadata"], @max_metadata_bytes),
         {:ok, created_at, 0} <- DateTime.from_iso8601(payload["created_at"]),
         :ok <- bounded_external(payload, @max_entry_bytes),
         {:ok, _canonical} <- TaintEnvelope.canonical_json(payload) do
      {:ok,
       %{
         id: payload["id"],
         agent_id: expected_agent_id,
         text: payload["text"],
         significant: payload["significant"],
         created_at: created_at,
         metadata: payload["metadata"]
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  def entry_from_payload(_payload, _expected_agent_id), do: {:error, :invalid_payload}

  @spec encode_aggregate([{map(), Taint.t()}]) ::
          {:ok, map(), Taint.t()} | {:error, atom()}
  def encode_aggregate(items) do
    with :ok <- bounded_proper_list(items, @max_entries),
         false <- items == [],
         :ok <- bounded_external(items, @max_aggregate_bytes),
         {:ok, persisted_items, taints} <- encode_items(items, [], []),
         true <- unique_persisted_ids?(persisted_items),
         {:ok, aggregate_taint} <- Taint.join_many(Enum.reverse(taints)),
         aggregate <- %{"version" => @version, "entries" => Enum.reverse(persisted_items)},
         :ok <- bounded_external(aggregate, @max_aggregate_bytes),
         {:ok, _canonical} <- TaintEnvelope.canonical_json(aggregate) do
      {:ok, aggregate, aggregate_taint}
    else
      _ -> {:error, :invalid_aggregate}
    end
  rescue
    _ -> {:error, :invalid_aggregate}
  catch
    _, _ -> {:error, :invalid_aggregate}
  end

  @spec decode_aggregate(String.t(), term(), Taint.t(), provenance_status(), pos_integer()) ::
          {:ok, [decoded_item()]} | {:error, atom()}
  def decode_aggregate(agent_id, aggregate, outer_taint, outer_status, limit) do
    with :ok <- validate_identifier(agent_id),
         true <- outer_status in [:verified, :legacy_unlabeled, :invalid_durable_provenance],
         {:ok, outer_taint} <- Taint.canonicalize(outer_taint),
         true <- is_integer(limit) and limit > 0 and limit <= @max_entries,
         :ok <- bounded_external(aggregate, @max_aggregate_bytes) do
      decode_by_outer_status(agent_id, aggregate, outer_taint, outer_status, limit)
    else
      _ -> {:error, :invalid_aggregate}
    end
  rescue
    _ -> {:error, :invalid_aggregate}
  catch
    _, _ -> {:error, :invalid_aggregate}
  end

  @spec status_for(Taint.t(), provenance_status()) :: provenance_status()
  def status_for(taint, status) do
    case Taint.canonicalize(taint) do
      {:ok, %Taint{} = taint} ->
        cond do
          provenance_marker?(taint, "invalid_durable_provenance") ->
            :invalid_durable_provenance

          provenance_marker?(taint, "legacy_unlabeled") ->
            :legacy_unlabeled

          status in [:verified, :legacy_unlabeled, :invalid_durable_provenance] ->
            status

          true ->
            :invalid_durable_provenance
        end

      _ ->
        :invalid_durable_provenance
    end
  rescue
    _ -> :invalid_durable_provenance
  catch
    _, _ -> :invalid_durable_provenance
  end

  defp encode_items([], persisted, taints), do: {:ok, persisted, taints}

  defp encode_items([{entry, taint} | rest], persisted, taints) do
    with {:ok, taint} <- Taint.canonicalize(taint),
         {:ok, payload} <- entry_payload(entry),
         {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, envelope_map} <- TaintEnvelope.to_map(envelope) do
      item = %{"payload" => payload, "provenance" => envelope_map}
      encode_items(rest, [item | persisted], [taint | taints])
    else
      _ -> {:error, :invalid_aggregate}
    end
  end

  defp encode_items(_improper, _persisted, _taints), do: {:error, :invalid_aggregate}

  defp decode_by_outer_status(agent_id, aggregate, outer_taint, :verified, limit) do
    with {:ok, persisted_items} <- versioned_items(aggregate),
         {:ok, items} <- decode_versioned_items(persisted_items, agent_id, []),
         true <- unique_decoded_ids?(items),
         {:ok, joined} <- join_decoded_items(items) do
      decoded = if joined == outer_taint, do: items, else: invalidate_items(items)
      {:ok, Enum.take(decoded, limit)}
    end
  end

  defp decode_by_outer_status(agent_id, aggregate, outer_taint, :legacy_unlabeled, limit) do
    case versioned_items(aggregate) do
      {:ok, persisted_items} ->
        with {:ok, items} <- decode_versioned_items(persisted_items, agent_id, []),
             true <- unique_decoded_ids?(items),
             {:ok, worsened} <- join_legacy_outer(items, outer_taint, []) do
          {:ok, Enum.take(worsened, limit)}
        end

      {:error, _reason} ->
        with {:ok, payloads} <- legacy_or_versioned_payloads(aggregate),
             {:ok, entries} <- decode_payloads(payloads, agent_id, []),
             true <- unique_entry_ids?(entries) do
          decoded = label_entries(entries, TaintEnvelope.missing_fallback(), :legacy_unlabeled)
          {:ok, Enum.take(decoded, limit)}
        end
    end
  end

  defp decode_by_outer_status(
         agent_id,
         aggregate,
         _outer_taint,
         :invalid_durable_provenance,
         limit
       ) do
    with {:ok, payloads} <- legacy_or_versioned_payloads(aggregate),
         {:ok, entries} <- decode_payloads(payloads, agent_id, []),
         true <- unique_entry_ids?(entries) do
      decoded =
        label_entries(
          entries,
          TaintEnvelope.invalid_fallback(),
          :invalid_durable_provenance
        )

      {:ok, Enum.take(decoded, limit)}
    end
  end

  defp versioned_items(aggregate) when is_map(aggregate) and not is_struct(aggregate) do
    with true <- exact_keys?(aggregate, @aggregate_keys),
         true <- aggregate["version"] == @version,
         items <- aggregate["entries"],
         :ok <- bounded_proper_list(items, @max_entries) do
      {:ok, items}
    else
      _ -> {:error, :invalid_aggregate}
    end
  end

  defp versioned_items(_aggregate), do: {:error, :invalid_aggregate}

  defp legacy_or_versioned_payloads(aggregate)
       when is_map(aggregate) and not is_struct(aggregate) do
    cond do
      exact_keys?(aggregate, @aggregate_keys) and aggregate["version"] == @version ->
        with :ok <- bounded_proper_list(aggregate["entries"], @max_entries) do
          extract_versioned_payloads(aggregate["entries"], [])
        end

      exact_keys?(aggregate, ["entries"]) ->
        with :ok <- bounded_proper_list(aggregate["entries"], @max_entries) do
          {:ok, aggregate["entries"]}
        end

      true ->
        {:error, :invalid_aggregate}
    end
  end

  defp legacy_or_versioned_payloads(_aggregate), do: {:error, :invalid_aggregate}

  defp extract_versioned_payloads([], acc), do: {:ok, Enum.reverse(acc)}

  defp extract_versioned_payloads([item | rest], acc)
       when is_map(item) and not is_struct(item) do
    if exact_keys?(item, @item_keys) or exact_keys?(item, ["payload"]) do
      extract_versioned_payloads(rest, [item["payload"] | acc])
    else
      {:error, :invalid_aggregate}
    end
  end

  defp extract_versioned_payloads(_improper, _acc), do: {:error, :invalid_aggregate}

  defp decode_versioned_items([], _agent_id, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_versioned_items([item | rest], agent_id, acc)
       when is_map(item) and not is_struct(item) do
    with true <- exact_keys?(item, @item_keys) or exact_keys?(item, ["payload"]),
         payload when is_map(payload) <- item["payload"],
         {:ok, entry} <- entry_from_payload(payload, agent_id),
         {:ok, taint, status} <- resolve_item_provenance(item, payload) do
      decoded = {entry, taint, status_for(taint, status)}
      decode_versioned_items(rest, agent_id, [decoded | acc])
    else
      _ -> {:error, :invalid_aggregate}
    end
  end

  defp decode_versioned_items(_improper, _agent_id, _acc),
    do: {:error, :invalid_aggregate}

  defp resolve_item_provenance(item, payload) do
    if Map.has_key?(item, "provenance") do
      TaintEnvelope.resolve(item["provenance"], payload)
    else
      TaintEnvelope.resolve(:missing, payload)
    end
  end

  defp decode_payloads([], _agent_id, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_payloads([payload | rest], agent_id, acc) do
    case entry_from_payload(payload, agent_id) do
      {:ok, entry} -> decode_payloads(rest, agent_id, [entry | acc])
      {:error, _reason} -> {:error, :invalid_aggregate}
    end
  end

  defp decode_payloads(_improper, _agent_id, _acc), do: {:error, :invalid_aggregate}

  defp join_decoded_items([]), do: {:error, :invalid_aggregate}

  defp join_decoded_items(items) do
    items
    |> Enum.map(fn {_entry, taint, _status} -> taint end)
    |> Taint.join_many()
  end

  defp join_legacy_outer([], _outer_taint, acc), do: {:ok, Enum.reverse(acc)}

  defp join_legacy_outer([{entry, taint, status} | rest], outer_taint, acc) do
    with {:ok, joined} <- Taint.join(taint, outer_taint) do
      joined_status =
        if status == :invalid_durable_provenance,
          do: :invalid_durable_provenance,
          else: :legacy_unlabeled

      join_legacy_outer(rest, outer_taint, [{entry, joined, joined_status} | acc])
    end
  end

  defp join_legacy_outer(_items, _outer_taint, _acc),
    do: {:error, :invalid_aggregate}

  defp invalidate_items(items) do
    label_entries(
      Enum.map(items, &elem(&1, 0)),
      TaintEnvelope.invalid_fallback(),
      :invalid_durable_provenance
    )
  end

  defp label_entries(entries, taint, status) do
    Enum.map(entries, &{&1, taint, status})
  end

  defp provenance_marker?(%Taint{source: marker}, marker), do: true

  defp provenance_marker?(%Taint{chain: chain}, marker),
    do: chain_marker?(chain, marker, Taint.max_chain_entries())

  defp chain_marker?([], _marker, _remaining), do: false

  defp chain_marker?([marker | _rest], marker, remaining) when remaining > 0,
    do: true

  defp chain_marker?([_entry | rest], marker, remaining) when remaining > 0,
    do: chain_marker?(rest, marker, remaining - 1)

  defp chain_marker?(_chain, _marker, _remaining), do: false

  defp unique_persisted_ids?(items) do
    ids = Enum.map(items, &get_in(&1, ["payload", "id"]))
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp unique_decoded_ids?(items) do
    items
    |> Enum.map(&elem(&1, 0))
    |> unique_entry_ids?()
  end

  defp unique_entry_ids?(entries) do
    ids = Enum.map(entries, & &1.id)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp exact_keys?(map, keys) when is_map(map) do
    map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  rescue
    _ -> false
  end

  defp exact_keys?(_map, _keys), do: false

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp validate_identifier(value) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and
         String.valid?(value) and String.trim(value) != "" do
      :ok
    else
      {:error, :invalid_identifier}
    end
  end

  defp validate_identifier(_value), do: {:error, :invalid_identifier}

  defp validate_text(value) when is_binary(value) do
    if byte_size(value) <= @max_text_bytes and String.valid?(value),
      do: :ok,
      else: {:error, :invalid_text}
  end

  defp validate_text(_value), do: {:error, :invalid_text}

  defp bounded_external(value, max_bytes) do
    if :erlang.external_size(value) <= max_bytes,
      do: :ok,
      else: {:error, :payload_too_large}
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  defp bounded_proper_list(value, max), do: bounded_proper_list(value, max, 0)

  defp bounded_proper_list([], _max, _count), do: :ok

  defp bounded_proper_list([_head | tail], max, count) when count < max,
    do: bounded_proper_list(tail, max, count + 1)

  defp bounded_proper_list(_value, _max, _count), do: {:error, :invalid_list}
end
