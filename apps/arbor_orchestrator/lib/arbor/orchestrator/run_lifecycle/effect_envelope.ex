defmodule Arbor.Orchestrator.RunLifecycle.EffectEnvelope do
  @moduledoc """
  Pure same-library effect-envelope construction and validation.

  One bounded JSON-clean, string-keyed effect map per run. No full context,
  outputs, credentials, arbitrary metadata, rich structs, PIDs, refs, or
  lossy truncation. Unknown keys and atom/string key aliases are rejected.

  Status machine (owner-driven; this module only constructs/validates maps):

  - `pending` — pre-effect intent recorded by the journal owner
    (backend-first when a store is configured; default journal storage is
    volatile/process-lifetime and is **not** crash durable)
  - `completed` — receipt recorded (outcome + result digest)
  - `settled` — terminal acknowledgment; evidence retained

  Generation is a positive JSON-safe integer (`1..2^53-1`). Record-level
  `effect_generation` defaults to `0` when no effect has been prepared.
  """

  @schema_version 1
  # JSON-safe integer ceiling (2^53 - 1). Compare only — never encode bignums.
  @max_json_safe_int 9_007_199_254_740_991
  @max_id_bytes 256
  @max_handler_bytes 256
  @max_iso_bytes 64
  @hash_hex_bytes 64
  # Closed full-envelope key count: 10 pending identity + 3 receipt fields.
  @max_envelope_keys 13

  @idempotency_classes MapSet.new([
                         "read_only",
                         "idempotent",
                         "idempotent_with_key",
                         "side_effecting"
                       ])

  @statuses MapSet.new(["pending", "completed", "settled"])
  @outcome_statuses MapSet.new([
                      "success",
                      "partial_success",
                      "retry",
                      "fail",
                      "skipped"
                    ])

  @pending_required [
    "schema_version",
    "generation",
    "run_id",
    "node_id",
    "execution_id",
    "handler",
    "input_hash",
    "idempotency_class",
    "started_at",
    "status"
  ]

  @receipt_required [
    "completed_at",
    "outcome_status",
    "result_digest"
  ]

  @type effect :: %{required(String.t()) => term()}
  @type error_reason ::
          :invalid_type
          | :non_string_keys
          | :atom_string_key_alias
          | :unknown_keys
          | :missing_keys
          | :invalid_schema_version
          | :invalid_generation
          | :invalid_run_id
          | :invalid_node_id
          | :invalid_execution_id
          | :invalid_handler
          | :invalid_input_hash
          | :invalid_idempotency_class
          | :invalid_started_at
          | :invalid_status
          | :invalid_completed_at
          | :invalid_outcome_status
          | :invalid_result_digest
          | :receipt_not_allowed
          | :status_mismatch
          | {:oversized, atom()}
          | {:empty, atom()}
          | {:invalid_utf8, atom()}

  @doc "Maximum JSON-safe generation (2^53 - 1)."
  @spec max_generation() :: pos_integer()
  def max_generation, do: @max_json_safe_int

  @doc "Schema version for this envelope shape."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Build a validated pending effect envelope.

  `attrs` must be a string-keyed map with:
  `run_id`, `node_id`, `execution_id`, `handler`, `input_hash`,
  `idempotency_class`, `started_at`, and positive integer `generation`.
  """
  @spec new_pending(map()) :: {:ok, effect()} | {:error, error_reason()}
  def new_pending(attrs) when is_map(attrs) do
    with :ok <- preflight_keys(attrs),
         :ok <- reject_unknown_prepare_keys(attrs),
         :ok <- optional_schema_version(attrs),
         {:ok, generation} <- fetch_generation(attrs),
         {:ok, run_id} <- fetch_id(attrs, "run_id", :run_id),
         {:ok, node_id} <- fetch_id(attrs, "node_id", :node_id),
         {:ok, execution_id} <- fetch_id(attrs, "execution_id", :execution_id),
         {:ok, handler} <- fetch_handler(attrs),
         {:ok, input_hash} <- fetch_hash(attrs, "input_hash", :input_hash),
         {:ok, idempotency_class} <- fetch_idempotency_class(attrs),
         {:ok, started_at} <- fetch_iso8601(attrs, "started_at", :started_at) do
      effect = %{
        "schema_version" => @schema_version,
        "generation" => generation,
        "run_id" => run_id,
        "node_id" => node_id,
        "execution_id" => execution_id,
        "handler" => handler,
        "input_hash" => input_hash,
        "idempotency_class" => idempotency_class,
        "started_at" => started_at,
        "status" => "pending"
      }

      validate(effect)
    end
  end

  def new_pending(_), do: {:error, :invalid_type}

  @doc """
  Complete a pending envelope with a receipt.

  `attrs` must supply **exactly** `completed_at`, closed `outcome_status`, and
  exact 64-lower-hex `result_digest`. Unknown/control fields, atom keys,
  atom/string aliases, and oversized maps are rejected before projection.
  Pending identity fields are preserved exactly — no rebuild from partial attrs.
  """
  @spec complete(effect(), map()) :: {:ok, effect()} | {:error, error_reason()}
  def complete(pending, attrs) when is_map(pending) and is_map(attrs) do
    with {:ok, pending} <- validate(pending),
         :ok <- require_status(pending, "pending"),
         :ok <- preflight_keys(attrs, allow_empty?: false),
         :ok <- reject_unknown_receipt_keys(attrs),
         {:ok, completed_at} <- fetch_iso8601(attrs, "completed_at", :completed_at),
         {:ok, outcome_status} <- fetch_outcome_status(attrs),
         {:ok, result_digest} <- fetch_hash(attrs, "result_digest", :result_digest) do
      effect =
        pending
        |> Map.put("status", "completed")
        |> Map.put("completed_at", completed_at)
        |> Map.put("outcome_status", outcome_status)
        |> Map.put("result_digest", result_digest)

      validate(effect)
    end
  end

  def complete(_, _), do: {:error, :invalid_type}

  @doc """
  Validate receipt attrs in isolation (exact three string keys, closed values).

  Used by owner retry paths so unknown/control fields fail as invalid attrs
  rather than silently mismatching into a conflict or already_recorded.
  """
  @spec validate_receipt_attrs(map()) :: :ok | {:error, error_reason()}
  def validate_receipt_attrs(attrs) when is_map(attrs) do
    with :ok <- preflight_keys(attrs, allow_empty?: false),
         :ok <- reject_unknown_receipt_keys(attrs),
         {:ok, _} <- fetch_iso8601(attrs, "completed_at", :completed_at),
         {:ok, _} <- fetch_outcome_status(attrs),
         {:ok, _} <- fetch_hash(attrs, "result_digest", :result_digest) do
      :ok
    end
  end

  def validate_receipt_attrs(_), do: {:error, :invalid_type}

  @doc """
  Mark a completed envelope as settled without clearing receipt evidence.
  """
  @spec settle(effect()) :: {:ok, effect()} | {:error, error_reason()}
  def settle(completed) when is_map(completed) do
    with {:ok, completed} <- validate(completed),
         :ok <- require_status(completed, "completed") do
      effect = Map.put(completed, "status", "settled")
      validate(effect)
    end
  end

  def settle(_), do: {:error, :invalid_type}

  @doc """
  Validate a full effect envelope (pending, completed, or settled).

  Rejects unknown keys, atom keys / atom-string aliases, invalid types,
  oversized IDs, non-hex digests, and receipt fields on pending envelopes.
  """
  @spec validate(term()) :: {:ok, effect()} | {:error, error_reason()}
  def validate(effect) when is_map(effect) do
    with :ok <- preflight_keys(effect),
         :ok <- require_known_keys(effect),
         :ok <- require_pending_keys(effect),
         {:ok, schema_version} <- fetch_schema_version(effect),
         {:ok, generation} <- fetch_generation(effect),
         {:ok, run_id} <- fetch_id(effect, "run_id", :run_id),
         {:ok, node_id} <- fetch_id(effect, "node_id", :node_id),
         {:ok, execution_id} <- fetch_id(effect, "execution_id", :execution_id),
         {:ok, handler} <- fetch_handler(effect),
         {:ok, input_hash} <- fetch_hash(effect, "input_hash", :input_hash),
         {:ok, idempotency_class} <- fetch_idempotency_class(effect),
         {:ok, started_at} <- fetch_iso8601(effect, "started_at", :started_at),
         {:ok, status} <- fetch_status(effect),
         {:ok, receipt} <- validate_receipt_fields(effect, status) do
      base = %{
        "schema_version" => schema_version,
        "generation" => generation,
        "run_id" => run_id,
        "node_id" => node_id,
        "execution_id" => execution_id,
        "handler" => handler,
        "input_hash" => input_hash,
        "idempotency_class" => idempotency_class,
        "started_at" => started_at,
        "status" => status
      }

      {:ok, Map.merge(base, receipt)}
    end
  end

  def validate(_), do: {:error, :invalid_type}

  @doc """
  True when both maps are identical validated pending envelopes (exact match).
  """
  @spec same_pending?(term(), term()) :: boolean()
  def same_pending?(a, b) when is_map(a) and is_map(b) do
    with {:ok, left} <- validate(a),
         {:ok, right} <- validate(b),
         true <- left["status"] == "pending",
         true <- right["status"] == "pending" do
      left == right
    else
      _ -> false
    end
  end

  def same_pending?(_, _), do: false

  @doc """
  True when both maps are identical validated completed/settled receipts.
  """
  @spec same_receipt?(term(), term()) :: boolean()
  def same_receipt?(a, b) when is_map(a) and is_map(b) do
    with {:ok, left} <- validate(a),
         {:ok, right} <- validate(b),
         true <- left["status"] in ["completed", "settled"],
         true <- right["status"] in ["completed", "settled"] do
      left == right
    else
      _ -> false
    end
  end

  def same_receipt?(_, _), do: false

  @doc """
  Match a pending effect against prepare attrs (generation already assigned).

  Validates the **original** attrs map (no stringify/drop of malformed keys).
  Owner generation is filled only when absent; an explicit mismatched
  generation fails rather than being overwritten.
  """
  @spec matches_prepare_attrs?(effect(), map(), pos_integer()) :: boolean()
  def matches_prepare_attrs?(effect, attrs, generation)
      when is_map(effect) and is_map(attrs) and is_integer(generation) do
    case apply_owner_generation(attrs, generation) do
      {:ok, prepare_attrs} ->
        case new_pending(prepare_attrs) do
          {:ok, expected} -> same_pending?(effect, expected)
          {:error, _} -> false
        end

      {:error, _} ->
        false
    end
  end

  def matches_prepare_attrs?(_, _, _), do: false

  @doc """
  Match a completed/settled receipt against record_effect_receipt identity + attrs.
  """
  @spec matches_receipt?(effect(), pos_integer(), String.t(), map()) :: boolean()
  def matches_receipt?(effect, generation, execution_id, attrs)
      when is_map(effect) and is_integer(generation) and is_binary(execution_id) and is_map(attrs) do
    with {:ok, current} <- validate(effect),
         true <- current["status"] in ["completed", "settled"],
         true <- current["generation"] == generation,
         true <- current["execution_id"] == execution_id do
      pending_view =
        current
        |> Map.drop(@receipt_required)
        |> Map.put("status", "pending")

      case complete(pending_view, attrs) do
        {:ok, rebuilt} -> same_identity_and_receipt?(current, rebuilt)
        {:error, _} -> false
      end
    else
      _ -> false
    end
  end

  def matches_receipt?(_, _, _, _), do: false

  defp same_identity_and_receipt?(current, rebuilt) do
    Enum.all?(
      [
        "schema_version",
        "generation",
        "run_id",
        "node_id",
        "execution_id",
        "handler",
        "input_hash",
        "idempotency_class",
        "started_at",
        "completed_at",
        "outcome_status",
        "result_digest"
      ],
      fn key -> current[key] === rebuilt[key] end
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @prepare_allowed MapSet.new([
                     "schema_version",
                     "generation",
                     "run_id",
                     "node_id",
                     "execution_id",
                     "handler",
                     "input_hash",
                     "idempotency_class",
                     "started_at",
                     # status is owner-assigned; reject if caller supplies another value later
                     "status"
                   ])

  @receipt_allowed MapSet.new(@receipt_required)

  defp apply_owner_generation(attrs, generation) when is_map(attrs) do
    case Map.fetch(attrs, "generation") do
      :error ->
        {:ok, Map.put(attrs, "generation", generation)}

      {:ok, ^generation} ->
        {:ok, attrs}

      {:ok, _} ->
        {:error, :invalid_generation}
    end
  end

  defp reject_unknown_prepare_keys(map) do
    unknown =
      map
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@prepare_allowed, &1))

    if unknown == [] do
      case Map.get(map, "status") do
        nil -> :ok
        "pending" -> :ok
        _ -> {:error, :invalid_status}
      end
    else
      {:error, :unknown_keys}
    end
  end

  defp reject_unknown_receipt_keys(map) do
    unknown =
      map
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@receipt_allowed, &1))

    if unknown == [] do
      :ok
    else
      {:error, :unknown_keys}
    end
  end

  defp optional_schema_version(map) do
    case Map.fetch(map, "schema_version") do
      :error -> :ok
      {:ok, @schema_version} -> :ok
      {:ok, _} -> {:error, :invalid_schema_version}
    end
  end

  defp preflight_keys(map, opts \\ [])

  defp preflight_keys(map, opts) when is_map(map) do
    allow_empty? = Keyword.get(opts, :allow_empty?, true)

    # O(1) ceiling before Map.keys/scans — closed full-envelope maximum.
    cond do
      map_size(map) > @max_envelope_keys ->
        {:error, {:oversized, :map}}

      map_size(map) == 0 and not allow_empty? ->
        {:error, :missing_keys}

      true ->
        keys = Map.keys(map)

        with :ok <- reject_atom_string_aliases(keys, map),
             :ok <- require_string_keys(keys) do
          :ok
        end
    end
  end

  defp preflight_keys(_, _), do: {:error, :invalid_type}

  defp reject_atom_string_aliases(keys, map) do
    Enum.reduce_while(keys, :ok, fn
      key, :ok when is_atom(key) ->
        if Map.has_key?(map, Atom.to_string(key)) do
          {:halt, {:error, :atom_string_key_alias}}
        else
          {:cont, :ok}
        end

      _key, :ok ->
        {:cont, :ok}
    end)
  end

  defp require_string_keys(keys) do
    if Enum.all?(keys, &is_binary/1) do
      :ok
    else
      {:error, :non_string_keys}
    end
  end

  defp require_known_keys(map) do
    allowed =
      case map["status"] do
        "pending" ->
          MapSet.new(@pending_required)

        status when status in ["completed", "settled"] ->
          MapSet.new(@pending_required ++ @receipt_required)

        _ ->
          MapSet.new(@pending_required ++ @receipt_required)
      end

    unknown =
      map
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))

    if unknown == [] do
      :ok
    else
      {:error, :unknown_keys}
    end
  end

  defp require_pending_keys(map) do
    missing = Enum.reject(@pending_required, &Map.has_key?(map, &1))

    if missing == [] do
      :ok
    else
      {:error, :missing_keys}
    end
  end

  defp validate_receipt_fields(map, "pending") do
    if Enum.any?(@receipt_required, &Map.has_key?(map, &1)) do
      {:error, :receipt_not_allowed}
    else
      {:ok, %{}}
    end
  end

  defp validate_receipt_fields(map, status) when status in ["completed", "settled"] do
    missing = Enum.reject(@receipt_required, &Map.has_key?(map, &1))

    if missing != [] do
      {:error, :missing_keys}
    else
      with {:ok, completed_at} <- fetch_iso8601(map, "completed_at", :completed_at),
           {:ok, outcome_status} <- fetch_outcome_status(map),
           {:ok, result_digest} <- fetch_hash(map, "result_digest", :result_digest) do
        {:ok,
         %{
           "completed_at" => completed_at,
           "outcome_status" => outcome_status,
           "result_digest" => result_digest
         }}
      end
    end
  end

  defp require_status(%{"status" => status}, expected) when status == expected, do: :ok
  defp require_status(_, _), do: {:error, :status_mismatch}

  defp fetch_schema_version(map) do
    case Map.fetch(map, "schema_version") do
      {:ok, @schema_version} -> {:ok, @schema_version}
      {:ok, _} -> {:error, :invalid_schema_version}
      :error -> {:error, :missing_keys}
    end
  end

  defp fetch_generation(map) do
    case Map.fetch(map, "generation") do
      {:ok, n} when is_integer(n) and n >= 1 and n <= @max_json_safe_int ->
        {:ok, n}

      {:ok, _} ->
        {:error, :invalid_generation}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp fetch_status(map) do
    case Map.fetch(map, "status") do
      {:ok, status} when is_binary(status) ->
        if MapSet.member?(@statuses, status) do
          {:ok, status}
        else
          {:error, :invalid_status}
        end

      {:ok, _} ->
        {:error, :invalid_status}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp fetch_idempotency_class(map) do
    case Map.fetch(map, "idempotency_class") do
      {:ok, class} when is_binary(class) ->
        if MapSet.member?(@idempotency_classes, class) do
          {:ok, class}
        else
          {:error, :invalid_idempotency_class}
        end

      {:ok, _} ->
        {:error, :invalid_idempotency_class}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp fetch_outcome_status(map) do
    case Map.fetch(map, "outcome_status") do
      {:ok, status} when is_binary(status) ->
        if MapSet.member?(@outcome_statuses, status) do
          {:ok, status}
        else
          {:error, :invalid_outcome_status}
        end

      {:ok, _} ->
        {:error, :invalid_outcome_status}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp fetch_id(map, key, field) do
    case Map.fetch(map, key) do
      {:ok, value} -> bound_identity(value, field, @max_id_bytes)
      :error -> {:error, :missing_keys}
    end
  end

  defp fetch_handler(map) do
    case Map.fetch(map, "handler") do
      {:ok, value} -> bound_identity(value, :handler, @max_handler_bytes)
      :error -> {:error, :missing_keys}
    end
  end

  defp fetch_hash(map, key, field) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        cond do
          byte_size(value) != @hash_hex_bytes ->
            {:error, invalid_hash_reason(field)}

          not String.valid?(value) ->
            {:error, {:invalid_utf8, field}}

          not match?(<<_::binary-size(@hash_hex_bytes)>>, value) ->
            {:error, invalid_hash_reason(field)}

          not lowercase_hex?(value) ->
            {:error, invalid_hash_reason(field)}

          true ->
            {:ok, value}
        end

      {:ok, _} ->
        {:error, invalid_hash_reason(field)}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp invalid_hash_reason(:input_hash), do: :invalid_input_hash
  defp invalid_hash_reason(:result_digest), do: :invalid_result_digest
  defp invalid_hash_reason(_), do: :invalid_input_hash

  defp lowercase_hex?(<<>>), do: true

  defp lowercase_hex?(<<c, rest::binary>>)
       when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f),
       do: lowercase_hex?(rest)

  defp lowercase_hex?(_), do: false

  defp fetch_iso8601(map, key, field) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        cond do
          value == "" ->
            {:error, {:empty, field}}

          byte_size(value) > @max_iso_bytes ->
            {:error, {:oversized, field}}

          not String.valid?(value) ->
            {:error, {:invalid_utf8, field}}

          true ->
            case DateTime.from_iso8601(value) do
              {:ok, _dt, _offset} ->
                {:ok, value}

              {:error, _} ->
                {:error, iso_error(field)}
            end
        end

      {:ok, _} ->
        {:error, iso_error(field)}

      :error ->
        {:error, :missing_keys}
    end
  end

  defp iso_error(:started_at), do: :invalid_started_at
  defp iso_error(:completed_at), do: :invalid_completed_at
  defp iso_error(_), do: :invalid_started_at

  defp bound_identity(value, field, max_bytes) when is_binary(value) do
    cond do
      value == "" ->
        {:error, {:empty, field}}

      byte_size(value) > max_bytes ->
        {:error, {:oversized, field}}

      not String.valid?(value) ->
        {:error, {:invalid_utf8, field}}

      true ->
        {:ok, value}
    end
  end

  defp bound_identity(_, field, _) do
    case field do
      :run_id -> {:error, :invalid_run_id}
      :node_id -> {:error, :invalid_node_id}
      :execution_id -> {:error, :invalid_execution_id}
      :handler -> {:error, :invalid_handler}
      _ -> {:error, :invalid_type}
    end
  end
end
