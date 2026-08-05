defmodule Arbor.Contracts.Security.TaintEnvelope do
  @moduledoc """
  Versioned, payload-bound durable provenance for arbitrary JSON-shaped values.

  The envelope is deliberately separate from the process-local `%Taint{}`. Its
  persisted form is a closed string-keyed map and its digest binds the exact
  canonical JSON projection that the caller stored alongside it.

  `canonical_json_v1` orders object keys by Erlang binary order (the UTF-8 byte
  order of their normalized string keys). It is deterministic but intentionally
  is not an RFC 8785 implementation.

  Per-container key/item ceilings and the global node ceiling jointly bound total
  traversal. Separate total key/item counters are intentionally omitted because
  every key or item leads to a counted value node, so equal-sized total counters
  would be unreachable policy behind `max_nodes`.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.Taint

  @version 1
  @payload_encoding "canonical_json_v1"
  @max_depth 32
  @max_nodes 4_096
  @max_object_keys 256
  @max_array_items 256
  @max_string_bytes 65_536
  @max_payload_bytes 1_048_576
  @max_integer 9_007_199_254_740_991
  @fields [:version, :payload_encoding, :payload_sha256, :taint]
  @input_fields [:payload, :taint]
  @persisted_fields Enum.map(@fields, &Atom.to_string/1)
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @fallback_missing %Taint{
    level: :untrusted,
    sensitivity: :restricted,
    sanitizations: 0,
    confidence: :unverified,
    source: "legacy_unlabeled",
    chain: []
  }

  typedstruct enforce: true do
    field(:version, pos_integer())
    field(:payload_encoding, String.t())
    field(:payload_sha256, String.t())
    field(:taint, Taint.t())
  end

  @doc "Returns the supported durable envelope version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the name of the deterministic payload encoding."
  @spec payload_encoding() :: String.t()
  def payload_encoding, do: @payload_encoding

  @doc "Returns the configured canonicalization ceilings."
  @spec limits() :: map()
  def limits do
    %{
      max_depth: @max_depth,
      max_nodes: @max_nodes,
      max_object_keys: @max_object_keys,
      max_array_items: @max_array_items,
      max_string_bytes: @max_string_bytes,
      max_payload_bytes: @max_payload_bytes,
      max_integer: @max_integer
    }
  end

  @doc "Constructs an envelope from `{payload, taint}` attributes."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, normalized} <- exact_input_attributes(attrs),
         {:ok, taint} <- Taint.canonicalize(normalized.taint),
         {:ok, payload_sha256} <- payload_sha256(normalized.payload) do
      {:ok,
       %__MODULE__{
         version: @version,
         payload_encoding: @payload_encoding,
         payload_sha256: payload_sha256,
         taint: taint
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_envelope_input}

  @doc "Convenience constructor that binds a taint to a payload projection."
  @spec new(term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(payload, taint), do: new(%{payload: payload, taint: taint})

  @doc "Returns the exact string-keyed durable representation of an envelope."
  @spec to_map(term()) :: {:ok, map()} | {:error, atom()}
  def to_map(%__MODULE__{} = envelope) do
    if exact_struct_shape?(envelope) and valid_envelope_fields?(envelope) do
      with {:ok, taint} <- Taint.to_persisted(envelope.taint) do
        {:ok,
         %{
           "version" => envelope.version,
           "payload_encoding" => envelope.payload_encoding,
           "payload_sha256" => envelope.payload_sha256,
           "taint" => taint
         }}
      end
    else
      {:error, :invalid_envelope}
    end
  end

  def to_map(_envelope), do: {:error, :invalid_envelope}

  @doc "Returns the canonical JSON bytes for a JSON-shaped payload projection."
  @spec canonical_json(term()) :: {:ok, binary()} | {:error, atom()}
  def canonical_json(payload) do
    with {:ok, canonical, _state} <- canonicalize_json(payload, initial_state(), 0),
         {:ok, bytes} <- Jason.encode(canonical),
         :ok <- bounded_payload(bytes) do
      {:ok, bytes}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  catch
    _, _ -> {:error, :invalid_payload}
  end

  @doc "Computes the lowercase SHA-256 digest of canonical payload bytes."
  @spec payload_sha256(term()) :: {:ok, String.t()} | {:error, atom()}
  def payload_sha256(payload) do
    with {:ok, bytes} <- canonical_json(payload) do
      {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  rescue
    _ -> {:error, :invalid_payload}
  end

  @doc "Strictly verifies a persisted envelope against its payload projection."
  @spec verify(term(), term()) :: {:ok, t()} | {:error, atom()}
  def verify(persisted, payload) do
    with {:ok, envelope} <- decode_persisted(persisted),
         {:ok, digest} <- payload_sha256(payload),
         true <- secure_equal?(digest, envelope.payload_sha256) do
      {:ok, envelope}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      false -> {:error, :payload_mismatch}
      _ -> {:error, :invalid_envelope}
    end
  end

  @doc "Resolves persisted provenance conservatively without exposing invalid data."
  @spec resolve(:missing | term(), term()) ::
          {:ok, Taint.t(), :verified | :legacy_unlabeled | :invalid_durable_provenance}
  def resolve(:missing, _payload), do: {:ok, @fallback_missing, :legacy_unlabeled}

  def resolve(persisted, payload) do
    case verify(persisted, payload) do
      {:ok, envelope} -> {:ok, envelope.taint, :verified}
      {:error, _reason} -> {:ok, Taint.invalid_durable_provenance(), :invalid_durable_provenance}
    end
  end

  @doc "Returns the exact missing-provenance fallback label."
  @spec missing_fallback() :: Taint.t()
  def missing_fallback, do: @fallback_missing

  @doc "Returns the exact malformed-provenance fallback label."
  @spec invalid_fallback() :: Taint.t()
  def invalid_fallback, do: Taint.invalid_durable_provenance()

  @doc "Decodes and validates a persisted map without checking a payload digest."
  @spec decode_persisted(term()) :: {:ok, t()} | {:error, atom()}
  def decode_persisted(value) when is_map(value) do
    with :ok <- exact_persisted_keys(value),
         :ok <- validate_version(value["version"]),
         :ok <- validate_encoding(value["payload_encoding"]),
         :ok <- validate_digest(value["payload_sha256"]),
         {:ok, taint} <- decode_persisted_taint(value["taint"]) do
      {:ok,
       %__MODULE__{
         version: @version,
         payload_encoding: @payload_encoding,
         payload_sha256: value["payload_sha256"],
         taint: taint
       }}
    end
  end

  def decode_persisted(_value), do: {:error, :invalid_envelope}

  defp exact_input_attributes(attrs) when is_map(attrs) and not is_struct(attrs) do
    if map_size(attrs) != length(@input_fields) do
      {:error, :invalid_envelope_input}
    else
      keys = Map.keys(attrs)

      if Enum.sort(keys) == Enum.sort(@input_fields),
        do: {:ok, attrs},
        else: {:error, :invalid_envelope_input}
    end
  end

  defp exact_input_attributes(attrs) when is_list(attrs), do: collect_input_keyword(attrs, %{})
  defp exact_input_attributes(_attrs), do: {:error, :invalid_envelope_input}

  defp collect_input_keyword([], attrs) when map_size(attrs) == length(@input_fields),
    do: {:ok, attrs}

  defp collect_input_keyword([], _attrs), do: {:error, :invalid_envelope_input}

  defp collect_input_keyword([{key, value} | rest], attrs) when key in @input_fields do
    if Map.has_key?(attrs, key),
      do: {:error, :invalid_envelope_input},
      else: collect_input_keyword(rest, Map.put(attrs, key, value))
  end

  defp collect_input_keyword(_value, _attrs), do: {:error, :invalid_envelope_input}

  defp exact_persisted_keys(value) do
    cond do
      map_size(value) != length(@persisted_fields) ->
        {:error, :invalid_envelope_shape}

      true ->
        keys = Map.keys(value)

        cond do
          Enum.any?(keys, &(not is_binary(&1))) -> {:error, :mixed_keys}
          Enum.sort(keys) != Enum.sort(@persisted_fields) -> {:error, :invalid_envelope_shape}
          true -> :ok
        end
    end
  end

  defp validate_version(@version), do: :ok
  defp validate_version(_value), do: {:error, :unsupported_version}

  defp validate_encoding(@payload_encoding), do: :ok
  defp validate_encoding(_value), do: {:error, :unsupported_encoding}

  defp validate_digest(value) when is_binary(value) do
    cond do
      byte_size(value) != 64 -> {:error, :invalid_hash}
      not String.valid?(value) -> {:error, :invalid_hash}
      Regex.match?(@sha256_pattern, value) -> :ok
      true -> {:error, :invalid_hash}
    end
  end

  defp validate_digest(_value), do: {:error, :invalid_hash}

  defp decode_persisted_taint(value) when is_map(value) do
    cond do
      map_size(value) != length(Taint.fields()) ->
        {:error, :invalid_taint}

      true ->
        keys = Map.keys(value)

        cond do
          Enum.any?(keys, &(not is_binary(&1))) ->
            {:error, :mixed_keys}

          Enum.sort(keys) != Enum.sort(Enum.map(Taint.fields(), &Atom.to_string/1)) ->
            {:error, :invalid_taint}

          persisted_taint_values?(value) ->
            Taint.canonicalize(%{
              level: value["level"],
              sensitivity: value["sensitivity"],
              sanitizations: value["sanitizations"],
              confidence: value["confidence"],
              source: value["source"],
              chain: value["chain"]
            })

          true ->
            {:error, :invalid_taint}
        end
    end
  end

  defp decode_persisted_taint(_value), do: {:error, :invalid_taint}

  defp persisted_taint_values?(value) do
    is_binary(value["level"]) and is_binary(value["sensitivity"]) and
      is_integer(value["sanitizations"]) and is_binary(value["confidence"]) and
      (is_nil(value["source"]) or is_binary(value["source"])) and
      valid_persisted_chain?(value["chain"], Taint.max_chain_entries())
  end

  defp valid_persisted_chain?([], _remaining), do: true

  defp valid_persisted_chain?([entry | rest], remaining)
       when remaining > 0 and is_binary(entry),
       do: valid_persisted_chain?(rest, remaining - 1)

  defp valid_persisted_chain?(_chain, _remaining), do: false

  defp valid_envelope_fields?(%__MODULE__{} = envelope) do
    envelope.version == @version and envelope.payload_encoding == @payload_encoding and
      validate_digest(envelope.payload_sha256) == :ok and
      match?({:ok, _}, Taint.canonicalize(envelope.taint))
  rescue
    _ -> false
  end

  defp exact_struct_shape?(%__MODULE__{} = envelope) do
    map_size(envelope) == length(@fields) + 1 and
      Enum.sort(Map.keys(envelope)) == Enum.sort([:__struct__ | @fields])
  end

  defp initial_state, do: %{nodes: 0, bytes: 0}

  defp canonicalize_json(_value, _state, depth) when depth > @max_depth,
    do: {:error, :payload_depth_exceeded}

  defp canonicalize_json(value, state, depth) when is_map(value) do
    cond do
      is_struct(value) ->
        {:error, :unsupported_payload}

      map_size(value) > @max_object_keys ->
        {:error, :payload_object_limit}

      true ->
        with {:ok, state} <- enter_node(state),
             {:ok, state} <- add_estimated_bytes(state, 2),
             {:ok, pairs, state} <- canonicalize_map(Map.to_list(value), state, depth, %{}) do
          {:ok, Jason.OrderedObject.new(Enum.sort(pairs)), state}
        end
    end
  end

  defp canonicalize_json(value, state, depth) when is_list(value) do
    with {:ok, state} <- enter_node(state),
         {:ok, state} <- add_estimated_bytes(state, 2),
         {:ok, values, state} <- canonicalize_list(value, state, depth, 0, []) do
      {:ok, values, state}
    else
      {:error, :payload_array_limit} -> {:error, :payload_array_limit}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :improper_payload}
    end
  end

  defp canonicalize_json(value, state, _depth) when is_binary(value) do
    cond do
      byte_size(value) > @max_string_bytes ->
        {:error, :payload_string_limit}

      not String.valid?(value) ->
        {:error, :invalid_payload_string}

      true ->
        with {:ok, state} <- enter_node(state),
             {:ok, state} <- add_estimated_bytes(state, byte_size(value) * 6 + 2) do
          {:ok, value, state}
        end
    end
  end

  defp canonicalize_json(value, state, _depth) when is_integer(value) do
    if abs(value) <= @max_integer do
      with {:ok, state} <- enter_node(state),
           {:ok, state} <- add_estimated_bytes(state, byte_size(Integer.to_string(value))) do
        {:ok, value, state}
      end
    else
      {:error, :payload_number_limit}
    end
  end

  defp canonicalize_json(value, state, _depth) when is_float(value) do
    with true <- finite_float?(value),
         {:ok, normalized} <- normalize_float(value) do
      case normalized do
        integer when is_integer(integer) ->
          canonicalize_json(integer, state, 0)

        float when is_float(float) ->
          with {:ok, state} <- enter_node(state),
               {:ok, number_bytes} <- float_bytes(float),
               {:ok, state} <- add_estimated_bytes(state, number_bytes) do
            {:ok, float, state}
          end
      end
    else
      false -> {:error, :non_finite_number}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonicalize_json(value, state, _depth) when is_boolean(value) or is_nil(value) do
    bytes = if is_nil(value), do: 4, else: if(value, do: 4, else: 5)

    with {:ok, state} <- enter_node(state),
         {:ok, state} <- add_estimated_bytes(state, bytes) do
      {:ok, value, state}
    end
  end

  defp canonicalize_json(value, state, depth) when is_atom(value) do
    canonicalize_json(Atom.to_string(value), state, depth)
  end

  defp canonicalize_json(_value, _state, _depth), do: {:error, :unsupported_payload}

  defp canonicalize_map([], state, _depth, acc), do: {:ok, Map.to_list(acc), state}

  defp canonicalize_map([{key, value} | rest], state, depth, acc) do
    with {:ok, key} <- canonical_key(key),
         false <- Map.has_key?(acc, key),
         {:ok, state} <- add_object_key(state, key),
         {:ok, value, state} <- canonicalize_json(value, state, depth + 1) do
      canonicalize_map(rest, state, depth, Map.put(acc, key, value))
    else
      true -> {:error, :payload_alias_collision}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_payload_key}
    end
  end

  defp canonicalize_map(_improper, _state, _depth, _acc), do: {:error, :unsupported_payload}

  defp canonicalize_list([], state, _depth, _count, acc), do: {:ok, Enum.reverse(acc), state}

  defp canonicalize_list([value | rest], state, depth, count, acc)
       when count < @max_array_items do
    with {:ok, state} <- add_array_item(state),
         {:ok, value, state} <- canonicalize_json(value, state, depth + 1) do
      canonicalize_list(rest, state, depth, count + 1, [value | acc])
    end
  end

  defp canonicalize_list([_value | _rest], _state, _depth, _count, _acc),
    do: {:error, :payload_array_limit}

  defp canonicalize_list(_improper, _state, _depth, _count, _acc), do: {:error, :improper_payload}

  defp canonical_key(key) when is_binary(key) do
    cond do
      byte_size(key) > @max_string_bytes -> {:error, :invalid_payload_key}
      not String.valid?(key) -> {:error, :invalid_payload_key}
      true -> {:ok, key}
    end
  end

  defp canonical_key(key) when is_atom(key), do: key |> Atom.to_string() |> canonical_key()
  defp canonical_key(_key), do: {:error, :unsupported_payload_key}

  defp enter_node(%{nodes: nodes} = state) when nodes < @max_nodes,
    do: {:ok, %{state | nodes: nodes + 1}}

  defp enter_node(_state), do: {:error, :payload_node_limit}

  defp add_object_key(state, key), do: add_estimated_bytes(state, byte_size(key) * 6 + 3)

  defp add_array_item(state), do: add_estimated_bytes(state, 1)

  defp add_estimated_bytes(%{bytes: bytes} = state, amount)
       when is_integer(amount) and amount >= 0 and bytes + amount <= @max_payload_bytes,
       do: {:ok, %{state | bytes: bytes + amount}}

  defp add_estimated_bytes(_state, _amount), do: {:error, :payload_byte_limit}

  defp bounded_payload(bytes) when byte_size(bytes) <= @max_payload_bytes, do: :ok
  defp bounded_payload(_bytes), do: {:error, :payload_byte_limit}

  defp finite_float?(value) do
    value == value and
      case :erlang.float_to_binary(value, [:compact]) do
        binary when is_binary(binary) ->
          not String.contains?(String.downcase(binary), ["nan", "inf"])
      end
  rescue
    _ -> false
  end

  defp normalize_float(value) do
    cond do
      abs(value) > @max_integer -> {:error, :payload_number_limit}
      value == 0.0 -> {:ok, 0}
      value == trunc(value) -> {:ok, trunc(value)}
      true -> {:ok, value}
    end
  rescue
    _ -> {:error, :non_finite_number}
  end

  defp float_bytes(value) do
    {:ok, byte_size(:erlang.float_to_binary(value, [:compact]))}
  rescue
    _ -> {:error, :non_finite_number}
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  rescue
    _ -> false
  end

  defp secure_equal?(_left, _right), do: false
end
