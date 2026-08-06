defmodule Arbor.Memory.EmbeddingCodec do
  @moduledoc false

  # Pure Memory-owned strict embedding codec. Constructs VectorOperation values
  # and decodes VectorRecord/VectorMatch values without side effects. Provenance
  # authority is a TaintEnvelope bound to canonical body bytes plus the exact
  # vector descriptor. Top-level :taint is source-owned Memory-boundary input;
  # payload keys named taint, provenance, model, provider, or digest remain
  # ordinary body data and never supply model or taint authority.

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorRecord}
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @kind "arbor_memory_embedding"
  @version 1
  @wrapper_keys ~w(kind version body provenance)
  @legacy_model_id "legacy:unspecified"
  @encoding_string "ieee754_float32_be_v1"
  # Contract-derived ceiling for guards (remote calls are illegal in guards).
  @max_batch_operations VectorOperation.max_batch_operations()

  @input_keys [
    :kind,
    :id,
    :agent_id,
    :source_namespace,
    :source_key,
    :payload,
    :vector,
    :category,
    :generation,
    :revision,
    :tombstone,
    :expected_generation,
    :expected_revision,
    :model_evidence,
    :taint
  ]

  @single_kinds [:insert, :update, :delete, :reinsert]

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance

  @type decoded_view :: %{
          id: String.t(),
          agent_id: String.t(),
          source_namespace: String.t(),
          source_key: String.t(),
          body: term(),
          vector: [float()],
          model_id: String.t(),
          dimensions: pos_integer(),
          encoding: VectorRecord.encoding(),
          category: String.t(),
          payload_digest: String.t(),
          vector_digest: String.t(),
          generation: non_neg_integer(),
          revision: non_neg_integer(),
          tombstone: boolean(),
          taint: Taint.t(),
          provenance_status: provenance_status()
        }

  @spec encode_operation(term()) ::
          {:ok, VectorOperation.t(), decoded_view()} | {:error, atom()}
  def encode_operation(input) do
    with {:ok, attrs} <- exact_input(input),
         {:ok, kind} <- normalize_kind(attrs.kind),
         {:ok, taint} <- Taint.canonicalize(attrs.taint),
         {:ok, body} <- canonicalize_body(attrs.payload),
         {:ok, model_id} <- resolve_model_id(attrs.model_evidence),
         {:ok, vector} <- VectorRecord.normalize_vector(attrs.vector),
         {:ok, vector_digest} <- VectorRecord.vector_digest(vector),
         {:ok, {^model_id, dimensions, encoding, category}} <-
           VectorRecord.validate_descriptor(
             model_id,
             VectorRecord.dimensions(),
             VectorRecord.encoding(),
             attrs.category
           ),
         projection <-
           provenance_projection(
             body,
             model_id,
             dimensions,
             encoding,
             category,
             vector_digest
           ),
         {:ok, envelope} <- TaintEnvelope.new(projection, taint),
         {:ok, provenance} <- TaintEnvelope.to_map(envelope),
         wrapper <- build_wrapper(body, provenance),
         {:ok, payload_digest} <- VectorRecord.payload_digest(wrapper),
         {:ok, record} <-
           VectorRecord.new(%{
             id: attrs.id,
             agent_id: attrs.agent_id,
             source_namespace: attrs.source_namespace,
             source_key: attrs.source_key,
             payload: wrapper,
             vector: vector,
             payload_digest: payload_digest,
             vector_digest: vector_digest,
             model_id: model_id,
             dimensions: dimensions,
             encoding: encoding,
             category: category,
             generation: attrs.generation,
             revision: attrs.revision,
             tombstone: attrs.tombstone
           }),
         {:ok, operation} <-
           VectorOperation.new(%{
             kind: kind,
             record: record,
             expected_generation: attrs.expected_generation,
             expected_revision: attrs.expected_revision
           }),
         {:ok, view} <- decode_record(record) do
      {:ok, operation, view}
    else
      {:error, reason} when is_atom(reason) -> {:error, map_error(reason)}
      _invalid -> {:error, :invalid_embedding_input}
    end
  rescue
    _ -> {:error, :invalid_embedding_input}
  catch
    _, _ -> {:error, :invalid_embedding_input}
  end

  @spec encode_batch(term()) ::
          {:ok, VectorOperation.t(), [decoded_view()]} | {:error, atom()}
  def encode_batch(inputs) do
    case collect_batch_items(inputs, [], [], 0) do
      {:ok, operations, views} ->
        case VectorOperation.new(%{kind: :batch, operations: operations}) do
          {:ok, batch} -> {:ok, batch, views}
          {:error, reason} -> {:error, map_error(reason)}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, map_error(reason)}

      _invalid ->
        {:error, :invalid_embedding_input}
    end
  rescue
    _ -> {:error, :invalid_embedding_input}
  catch
    _, _ -> {:error, :invalid_embedding_input}
  end

  @spec decode_record(term()) ::
          {:ok, decoded_view()} | {:error, :invalid_vector_record}
  def decode_record(record) do
    with {:ok, record} <- VectorRecord.validate(record),
         {:ok, body, taint, status} <- resolve_payload_provenance(record) do
      {:ok, decoded_view(record, body, taint, status)}
    else
      {:error, :invalid_vector_record} -> {:error, :invalid_vector_record}
      _invalid -> {:error, :invalid_vector_record}
    end
  rescue
    _ -> {:error, :invalid_vector_record}
  catch
    _, _ -> {:error, :invalid_vector_record}
  end

  @spec decode_match(term()) ::
          {:ok, %{match: decoded_view(), similarity: float()}}
          | {:error, :invalid_vector_match}
  def decode_match(match) do
    with {:ok, match} <- VectorMatch.validate(match),
         {:ok, view} <- decode_record(match.record) do
      {:ok, %{match: view, similarity: match.similarity}}
    else
      {:error, :invalid_vector_record} -> {:error, :invalid_vector_match}
      {:error, :invalid_vector_match} -> {:error, :invalid_vector_match}
      _invalid -> {:error, :invalid_vector_match}
    end
  rescue
    _ -> {:error, :invalid_vector_match}
  catch
    _, _ -> {:error, :invalid_vector_match}
  end

  @spec kind() :: String.t()
  def kind, do: @kind

  @spec version() :: pos_integer()
  def version, do: @version

  @spec legacy_model_id() :: String.t()
  def legacy_model_id, do: @legacy_model_id

  # Walk the batch incrementally: never call length/1 on the full input. Reject as
  # soon as the contract ceiling is exceeded so adversarial lists stay bounded.
  # @max_batch_operations is derived from VectorOperation.max_batch_operations/0
  # at compile time; the call itself cannot appear in a guard.
  defp collect_batch_items([], [], [], 0), do: {:error, :invalid_embedding_input}

  defp collect_batch_items([], operations, views, count) when count > 0 do
    {:ok, Enum.reverse(operations), Enum.reverse(views)}
  end

  defp collect_batch_items([_input | _rest], _operations, _views, count)
       when count >= @max_batch_operations do
    {:error, :invalid_embedding_input}
  end

  defp collect_batch_items([input | rest], operations, views, count) when is_list(rest) do
    case encode_operation(input) do
      {:ok, operation, view} ->
        collect_batch_items(rest, [operation | operations], [view | views], count + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_batch_items(_improper, _operations, _views, _count),
    do: {:error, :invalid_embedding_input}

  defp exact_input(attrs) when is_map(attrs) and not is_struct(attrs) do
    keys = Map.keys(attrs)

    cond do
      map_size(attrs) != length(@input_keys) ->
        {:error, :invalid_embedding_input}

      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_embedding_input}

      Enum.sort(keys) != Enum.sort(@input_keys) ->
        {:error, :invalid_embedding_input}

      true ->
        {:ok, Map.new(@input_keys, &{&1, Map.fetch!(attrs, &1)})}
    end
  end

  defp exact_input(attrs) when is_list(attrs), do: collect_keyword(attrs, %{})
  defp exact_input(_attrs), do: {:error, :invalid_embedding_input}

  defp collect_keyword([], attrs) when map_size(attrs) == length(@input_keys), do: {:ok, attrs}
  defp collect_keyword([], _attrs), do: {:error, :invalid_embedding_input}

  defp collect_keyword([{key, value} | rest], attrs) when key in @input_keys do
    if Map.has_key?(attrs, key) do
      {:error, :invalid_embedding_input}
    else
      collect_keyword(rest, Map.put(attrs, key, value))
    end
  end

  defp collect_keyword(_attrs, _acc), do: {:error, :invalid_embedding_input}

  defp normalize_kind(kind) when kind in @single_kinds, do: {:ok, kind}
  defp normalize_kind(_kind), do: {:error, :invalid_embedding_input}

  defp resolve_model_id(:absent), do: {:ok, @legacy_model_id}

  defp resolve_model_id({:provider_model, provider, model})
       when is_binary(provider) and is_binary(model) do
    model_id = provider <> "/" <> model
    max = VectorRecord.limits().model_id_bytes

    if byte_size(provider) > 0 and byte_size(model) > 0 and String.valid?(provider) and
         String.valid?(model) and byte_size(model_id) <= max and String.valid?(model_id) do
      {:ok, model_id}
    else
      {:error, :invalid_model_evidence}
    end
  end

  defp resolve_model_id({:model_id, model_id}) when is_binary(model_id) do
    max = VectorRecord.limits().model_id_bytes

    if byte_size(model_id) > 0 and byte_size(model_id) <= max and String.valid?(model_id) do
      {:ok, model_id}
    else
      {:error, :invalid_model_evidence}
    end
  end

  defp resolve_model_id(_evidence), do: {:error, :invalid_model_evidence}

  defp canonicalize_body(payload) when is_map(payload) and not is_struct(payload) do
    case VectorRecord.canonical_payload_bytes(payload) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, body} when is_map(body) -> {:ok, body}
          _ -> {:error, :invalid_embedding_input}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonicalize_body(_payload), do: {:error, :invalid_embedding_input}

  defp provenance_projection(body, model_id, dimensions, encoding, category, vector_digest) do
    %{
      "body" => body,
      "descriptor" => %{
        "model_id" => model_id,
        "dimensions" => dimensions,
        "encoding" => encoding_string(encoding),
        "category" => category,
        "vector_digest" => vector_digest
      }
    }
  end

  defp encoding_string(:ieee754_float32_be_v1), do: @encoding_string
  defp encoding_string(@encoding_string), do: @encoding_string
  defp encoding_string(other) when is_atom(other), do: Atom.to_string(other)
  defp encoding_string(other) when is_binary(other), do: other

  defp build_wrapper(body, provenance) do
    %{
      "kind" => @kind,
      "version" => @version,
      "body" => body,
      "provenance" => provenance
    }
  end

  # Claims of arbor_memory_embedding that are not an exact valid wrapper must never
  # downgrade to legacy_unlabeled; only payloads with no wrapper-kind claim are missing.
  defp resolve_payload_provenance(%VectorRecord{} = record) do
    case classify_payload(record.payload) do
      {:wrapper, body, provenance} ->
        projection =
          provenance_projection(
            body,
            record.model_id,
            record.dimensions,
            record.encoding,
            record.category,
            record.vector_digest
          )

        case TaintEnvelope.resolve(provenance, projection) do
          {:ok, taint, status} -> {:ok, body, taint, status}
        end

      {:malformed_wrapper, body} ->
        {:ok, body, TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}

      {:legacy, body} ->
        case TaintEnvelope.resolve(:missing, body) do
          {:ok, taint, status} -> {:ok, body, taint, status}
        end
    end
  end

  defp classify_payload(payload) when is_map(payload) and not is_struct(payload) do
    cond do
      exact_wrapper?(payload) ->
        {:wrapper, payload["body"], payload["provenance"]}

      claims_wrapper_kind?(payload) ->
        body =
          if is_map(payload["body"]) and not is_struct(payload["body"]),
            do: payload["body"],
            else: payload

        {:malformed_wrapper, body}

      true ->
        {:legacy, payload}
    end
  end

  defp classify_payload(payload), do: {:legacy, payload}

  defp exact_wrapper?(payload) do
    exact_string_keys?(payload, @wrapper_keys) and payload["kind"] == @kind and
      payload["version"] == @version and is_map(payload["body"]) and
      not is_struct(payload["body"])
  end

  defp claims_wrapper_kind?(payload) when is_map(payload) do
    Map.get(payload, "kind") == @kind
  end

  defp decoded_view(record, body, taint, status) do
    %{
      id: record.id,
      agent_id: record.agent_id,
      source_namespace: record.source_namespace,
      source_key: record.source_key,
      body: body,
      vector: record.vector,
      model_id: record.model_id,
      dimensions: record.dimensions,
      encoding: record.encoding,
      category: record.category,
      payload_digest: record.payload_digest,
      vector_digest: record.vector_digest,
      generation: record.generation,
      revision: record.revision,
      tombstone: record.tombstone,
      taint: taint,
      provenance_status: status
    }
  end

  defp exact_string_keys?(map, keys) when is_map(map) do
    map_keys = Map.keys(map)

    map_size(map) == length(keys) and Enum.all?(map_keys, &is_binary/1) and
      Enum.sort(map_keys) == Enum.sort(keys)
  end

  defp map_error(:invalid_vector_record), do: :invalid_vector_record
  defp map_error(:invalid_vector_operation), do: :invalid_vector_operation
  defp map_error(:invalid_model_evidence), do: :invalid_model_evidence
  defp map_error(:invalid_envelope_input), do: :invalid_provenance
  defp map_error(:invalid_envelope), do: :invalid_provenance
  defp map_error(:invalid_taint), do: :invalid_provenance
  defp map_error(:invalid_payload), do: :invalid_embedding_input
  defp map_error(reason) when is_atom(reason), do: reason
  defp map_error(_), do: :invalid_embedding_input
end
