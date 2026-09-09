defmodule Arbor.Memory.PrivateConversations do
  @moduledoc false

  # The public Memory facade supplies its existing ordinary capability gate.
  # Admission checks and signing run in that facade's caller (the Session), never
  # in an Index worker. Neither a scope map nor a persistence selector is public
  # input. The configured Security facade is a trusted application dependency.

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorReceipt, VectorRecord}
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.{Config, Embedding, EmbeddingEvidence, IndexOps, StrictVectorSeam}

  @scope_keys [:agent_id, :human_id, :engagement_id, :session_id, :turn_id]
  @body_keys ["content", "metadata", "source_id", "conversation_scope", "owner_stamp"]
  @view_keys [
    :id,
    :agent_id,
    :source_namespace,
    :source_key,
    :body,
    :vector,
    :model_id,
    :dimensions,
    :encoding,
    :category,
    :payload_digest,
    :vector_digest,
    :generation,
    :revision,
    :tombstone,
    :taint,
    :provenance_status
  ]
  @embedding_keys [:embedding, :provider, :model, :dimensions]
  @max_rows 1_000

  def index(admission, content, embedding_result, opts, authorize) do
    with {:ok, source_id} <- write_options(opts),
         :ok <- validate_content(content),
         {:ok, evidence} <- embedding_evidence(embedding_result),
         {:ok, scope} <- admitted_scope(admission, :write),
         :ok <- authorize.(scope, :write),
         {:ok, unsigned} <- unsigned_input(scope, source_id, content, evidence) do
      insert_or_replay(StrictVectorSeam.resolve(), admission, scope, unsigned)
    end
  end

  def recall(admission, embedding_result, opts, authorize) do
    with {:ok, query_opts} <- read_options(opts),
         {:ok, evidence} <- embedding_evidence(embedding_result),
         {:ok, scope} <- admitted_scope(admission, :read),
         :ok <- authorize.(scope, :read),
         {:ok, matches} <- search(StrictVectorSeam.resolve(), scope, evidence, query_opts),
         # Revocation while storage was being read cannot release the result.
         {:ok, ^scope} <- admitted_scope(admission, :read) do
      {:ok, matches}
    else
      {:ok, _changed_scope} -> {:error, :private_memory_unauthorized}
      error -> error
    end
  end

  defp admitted_scope(admission, operation) do
    with {:ok, scope} <- security_call(:authorize_private_memory_turn, [admission, operation]),
         true <- is_map(scope),
         true <- Enum.all?(@scope_keys, &valid_label?(Map.get(scope, &1))) do
      {:ok, Map.take(scope, @scope_keys)}
    else
      {:error, _} = error -> error
      _ -> {:error, :private_memory_unauthorized}
    end
  end

  defp unsigned_input(scope, source_id, content, evidence) do
    with {:ok, namespace} <- namespace(scope),
         {:ok, id} <- entry_id(scope, source_id) do
      body = %{
        "content" => content,
        "metadata" => %{"type" => "conversation"},
        "source_id" => source_id,
        "conversation_scope" => string_scope(scope)
      }

      input = %{
        kind: :insert,
        id: id,
        agent_id: scope.agent_id,
        source_namespace: namespace,
        source_key: id,
        payload: body,
        vector: evidence.vector,
        category: "conversation",
        generation: 0,
        revision: 0,
        tombstone: false,
        expected_generation: nil,
        expected_revision: nil,
        model_evidence: evidence.model_evidence,
        taint: TaintEnvelope.missing_fallback()
      }

      # Pure preflight checks the complete payload/descriptor before requesting a
      # stamp. The second encode adds that stamp to the same immutable input.
      with {:ok, _operation, view} <- Embedding.encode_strict_operation(input) do
        {:ok, %{input: input, view: view}}
      end
    end
  end

  defp insert_or_replay(seam, admission, scope, unsigned) do
    input = unsigned.input

    case vector_call(fn ->
           seam.fetch(scope.agent_id, input.source_namespace, input.source_key, [])
         end) do
      {:ok, view} ->
        replay_result(view, scope, unsigned)

      {:error, :not_found} ->
        insert(seam, admission, scope, unsigned)

      {:error, _} = error ->
        error

      _ ->
        {:error, :malformed_persistence_result}
    end
  end

  defp insert(seam, admission, scope, unsigned) do
    with {:ok, descriptor} <- descriptor(unsigned.view, scope),
         {:ok, stamp} <- security_call(:attest_private_memory_record, [admission, descriptor]),
         :ok <- security_call(:verify_private_memory_record, [descriptor, stamp]),
         input <- %{
           unsigned.input
           | payload: Map.put(unsigned.input.payload, "owner_stamp", stamp)
         },
         {:ok, operation, _view} <- Embedding.encode_strict_operation(input),
         {:ok, receipt} <- IndexOps.execute_or_reconcile(seam, scope.agent_id, operation),
         {:ok, _receipt} <- VectorReceipt.validate_for_operation(receipt, operation) do
      {:ok, input.source_key}
    else
      {:error, :conflict} ->
        # Concurrent retry: accept only an independently verified identical
        # source/content/vector. It retains the first write's sealed turn.
        case vector_call(fn ->
               seam.fetch(
                 scope.agent_id,
                 unsigned.input.source_namespace,
                 unsigned.input.source_key,
                 []
               )
             end) do
          {:ok, view} -> replay_result(view, scope, unsigned)
          {:error, _} = error -> error
          _ -> {:error, :malformed_persistence_result}
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :malformed_persistence_result}
    end
  end

  defp replay_result(view, scope, unsigned) do
    with {:ok, view} <- verified_view(view, scope),
         true <- view.id == unsigned.view.id,
         true <- view.body["source_id"] == unsigned.input.payload["source_id"],
         true <- view.body["content"] == unsigned.input.payload["content"],
         true <- view.vector_digest == unsigned.view.vector_digest,
         true <- view.model_id == unsigned.view.model_id do
      {:ok, view.source_key}
    else
      false -> {:error, :private_memory_source_conflict}
      error -> error
    end
  end

  defp search(seam, scope, evidence, query_opts) do
    with {:ok, namespace} <- namespace(scope) do
      search_opts = [
        source_namespace: namespace,
        category: "conversation",
        model_id: evidence.model_id,
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        threshold: query_opts.threshold,
        limit: query_opts.limit
      ]

      case vector_call(fn -> seam.search(scope.agent_id, evidence.vector, search_opts) end) do
        {:ok, matches} -> validate_matches(matches, scope, evidence, query_opts)
        {:error, :unsupported} -> local_search(seam, scope, evidence, query_opts, namespace)
        {:error, _} = error -> error
        _ -> {:error, :malformed_persistence_result}
      end
    end
  end

  defp local_search(seam, scope, evidence, query_opts, namespace) do
    opts = [source_namespace: namespace, include_tombstones: false, limit: @max_rows]

    with {:ok, views} <- vector_call(fn -> seam.list(scope.agent_id, opts) end),
         {:ok, verified} <- verify_views(views, scope) do
      matches =
        verified
        |> Enum.filter(&(&1.model_id == evidence.model_id))
        |> Enum.map(fn view ->
          %{match: view, similarity: cosine(evidence.vector, view.vector)}
        end)

      {:ok, present(matches, query_opts)}
    end
  end

  defp validate_matches(matches, scope, evidence, query_opts) when is_list(matches) do
    matches
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      with %{match: view, similarity: similarity} <- item,
           {:ok, similarity} <- VectorMatch.normalize_similarity(similarity),
           {:ok, view} <- verified_view(view, scope),
           true <- view.model_id == evidence.model_id do
        {:cont, {:ok, [%{match: view, similarity: similarity} | acc]}}
      else
        false -> {:halt, {:error, :descriptor_mismatch}}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :malformed_persistence_result}}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, present(verified, query_opts)}
      error -> error
    end
  end

  defp validate_matches(_, _, _, _), do: {:error, :malformed_persistence_result}

  defp verify_views(views, scope) when is_list(views) do
    Enum.reduce_while(views, {:ok, []}, fn view, {:ok, acc} ->
      case verified_view(view, scope) do
        {:ok, view} -> {:cont, {:ok, [view | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_views(_, _), do: {:error, :malformed_persistence_result}

  defp verified_view(view, scope) do
    with true <- exact_keys?(view, @view_keys),
         true <- exact_keys?(view.body, @body_keys),
         true <- view.body["metadata"] == %{"type" => "conversation"},
         true <- valid_label?(view.body["source_id"]),
         :ok <- validate_content(view.body["content"]),
         {:ok, stored_scope} <- stored_scope(view.body["conversation_scope"]),
         true <-
           stored_scope.agent_id == scope.agent_id and stored_scope.human_id == scope.human_id,
         {:ok, namespace} <- namespace(scope),
         {:ok, id} <- entry_id(scope, view.body["source_id"]),
         true <- view.agent_id == scope.agent_id and view.source_namespace == namespace,
         true <- view.id == id and view.source_key == id,
         true <- view.category == "conversation" and view.generation == 1 and view.revision == 1,
         true <- view.tombstone == false and view.provenance_status == :verified,
         true <- view.taint == TaintEnvelope.missing_fallback(),
         {:ok, canonical} <- reencode_view(view),
         true <- nonzero_vector?(canonical.vector),
         true <- canonical.payload_digest == view.payload_digest,
         true <- canonical.vector_digest == view.vector_digest,
         true <- canonical.model_id == view.model_id and canonical.dimensions == view.dimensions,
         true <- canonical.encoding == view.encoding,
         {:ok, descriptor} <- descriptor(view, stored_scope),
         :ok <-
           security_call(:verify_private_memory_record, [descriptor, view.body["owner_stamp"]]) do
      {:ok, %{view | vector: canonical.vector}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_private_memory_record}
    end
  end

  defp reencode_view(view) do
    input = %{
      kind: :insert,
      id: view.id,
      agent_id: view.agent_id,
      source_namespace: view.source_namespace,
      source_key: view.source_key,
      payload: view.body,
      vector: view.vector,
      category: view.category,
      generation: 0,
      revision: 0,
      tombstone: false,
      expected_generation: nil,
      expected_revision: nil,
      model_evidence: {:model_id, view.model_id},
      taint: view.taint
    }

    with {:ok, _operation, canonical} <- Embedding.encode_strict_operation(input),
         do: {:ok, canonical}
  end

  defp descriptor(view, scope) do
    with {:ok, body_digest} <- VectorRecord.payload_digest(Map.delete(view.body, "owner_stamp")),
         {:ok, vector_digest} <- VectorRecord.vector_digest(view.vector) do
      {:ok,
       Map.merge(string_scope(scope), %{
         "id" => view.id,
         "source_namespace" => view.source_namespace,
         "source_key" => view.source_key,
         "body_digest" => body_digest,
         "vector_digest" => vector_digest,
         "model_id" => view.model_id,
         "dimensions" => view.dimensions,
         "encoding" => Atom.to_string(view.encoding),
         "category" => view.category,
         "generation" => 1,
         "revision" => 1,
         "tombstone" => false
       })}
    end
  end

  defp stored_scope(scope) do
    keys = Enum.map(@scope_keys, &Atom.to_string/1)

    if exact_keys?(scope, keys) and Enum.all?(keys, &valid_label?(Map.get(scope, &1))) do
      {:ok, Map.new(@scope_keys, &{&1, Map.fetch!(scope, Atom.to_string(&1))})}
    else
      {:error, :invalid_private_memory_record}
    end
  end

  defp namespace(scope) do
    with {:ok, digest} <- VectorRecord.payload_digest([scope.agent_id, scope.human_id]),
         do: {:ok, "private_conversation_" <> digest}
  end

  defp entry_id(scope, source_id) do
    with {:ok, digest} <- VectorRecord.payload_digest([scope.agent_id, scope.human_id, source_id]),
         do: {:ok, "private_mem_" <> digest}
  end

  defp string_scope(scope), do: Map.new(@scope_keys, &{Atom.to_string(&1), Map.fetch!(scope, &1)})

  defp present(matches, opts) do
    matches
    |> Enum.sort_by(&{-&1.similarity, &1.match.id})
    |> Enum.uniq_by(& &1.match.id)
    |> Enum.filter(&(&1.similarity >= opts.threshold))
    |> Enum.take(opts.limit)
    |> Enum.map(fn %{match: view, similarity: similarity} ->
      %{
        id: view.id,
        content: view.body["content"],
        similarity: similarity,
        metadata: view.body["metadata"],
        model_id: view.model_id,
        provenance_status: :verified
      }
    end)
  end

  defp cosine(left, right) do
    {dot, left_norm, right_norm} =
      Enum.zip_reduce(left, right, {0.0, 0.0, 0.0}, fn a, b, {dot, an, bn} ->
        {dot + a * b, an + a * a, bn + b * b}
      end)

    max(-1.0, min(1.0, dot / :math.sqrt(left_norm * right_norm)))
  end

  defp write_options(opts) do
    with true <- valid_options?(opts, [:source_id]),
         source_id <- Keyword.get(opts, :source_id),
         true <- valid_label?(source_id) do
      {:ok, source_id}
    else
      _ -> {:error, :invalid_private_memory_options}
    end
  end

  defp read_options(opts) do
    with true <- valid_options?(opts, [:limit, :threshold]),
         limit <- Keyword.get(opts, :limit, 10),
         true <- is_integer(limit) and limit > 0 and limit <= @max_rows,
         threshold <- Keyword.get(opts, :threshold, 0.3),
         {:ok, threshold} <- VectorMatch.normalize_similarity(threshold) do
      {:ok, %{limit: limit, threshold: threshold}}
    else
      _ -> {:error, :invalid_private_memory_options}
    end
  end

  defp embedding_evidence(result) do
    with true <- exact_keys?(result, @embedding_keys),
         {:ok, evidence} <- EmbeddingEvidence.from_provider_result(result),
         true <- nonzero_vector?(evidence.vector),
         {:ok, _descriptor} <-
           VectorRecord.validate_descriptor(
             evidence.model_id,
             VectorRecord.dimensions(),
             VectorRecord.encoding(),
             "conversation"
           ) do
      {:ok, evidence}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_embedding}
    end
  end

  defp validate_content(content) do
    if is_binary(content) and content != "" and byte_size(content) <= 1_000_000 and
         String.valid?(content),
       do: :ok,
       else: {:error, :invalid_private_memory_content}
  end

  # Consume at most the allowed keys plus one refusal. Improper lists, duplicate
  # keys, and unknown options stop here before any Keyword call or owner I/O.
  defp valid_options?(opts, allowed), do: valid_options?(opts, allowed, [])
  defp valid_options?([], _allowed, _seen), do: true

  defp valid_options?([{key, _value} | rest], allowed, seen) when is_atom(key) do
    key in allowed and key not in seen and valid_options?(rest, allowed, [key | seen])
  end

  defp valid_options?(_, _, _), do: false
  defp nonzero_vector?(vector), do: Enum.any?(vector, &(&1 != 0.0))

  defp valid_label?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 256 and String.valid?(value)

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false

  defp security_call(function, args) do
    apply(Config.private_memory_security(), function, args)
  rescue
    _ -> {:error, :private_memory_security_unavailable}
  catch
    _, _ -> {:error, :private_memory_security_unavailable}
  end

  defp vector_call(fun) do
    fun.()
  rescue
    _ -> {:error, :indeterminate}
  catch
    _, _ -> {:error, :indeterminate}
  end
end
