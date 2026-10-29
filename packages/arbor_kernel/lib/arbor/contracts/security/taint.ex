defmodule Arbor.Contracts.Security.Taint do
  @moduledoc """
  Four-dimensional taint tracking for information flow control.

  Extends the original atom-based taint level with sensitivity classification,
  sanitization tracking, and confidence scoring. Together these dimensions enable:

  - **Level** — provenance tracking (trusted → hostile)
  - **Sensitivity** — data classification for provider routing (public → restricted)
  - **Sanitizations** — bitmask tracking which sanitization steps have been applied
  - **Confidence** — how much we trust the taint classification itself

  ## Defaults

  Conservative by design (council decisions #4, #6):
  - `:internal` sensitivity (not public by default)
  - 0 sanitizations (nothing has been cleaned)
  - `:unverified` confidence (we don't know how reliable the classification is)

  ## JSON compatibility

  The explicit Jason encoder preserves transient compatibility for validated
  taints and `TaintedValue`. It is not a durable representation. Durable callers
  must bind their payload through `Arbor.Contracts.Security.TaintEnvelope.to_map/1`.
  """

  use TypedStruct

  @type level :: :trusted | :derived | :untrusted | :hostile
  @type sensitivity :: :public | :internal | :confidential | :restricted
  @type confidence :: :unverified | :plausible | :corroborated | :verified

  # Phase 1 sanitization bit positions (8-bit)
  @xss 0b00000001
  @sqli 0b00000010
  @command_injection 0b00000100
  @path_traversal 0b00001000
  @prompt_injection 0b00010000
  @ssrf 0b00100000
  @log_injection 0b01000000
  @deserialization 0b10000000

  @sanitization_bits %{
    xss: @xss,
    sqli: @sqli,
    command_injection: @command_injection,
    path_traversal: @path_traversal,
    prompt_injection: @prompt_injection,
    ssrf: @ssrf,
    log_injection: @log_injection,
    deserialization: @deserialization
  }

  @taint_fields [:level, :sensitivity, :sanitizations, :confidence, :source, :chain]
  @string_taint_fields Enum.map(@taint_fields, &Atom.to_string/1)
  @max_source_bytes 128
  @max_chain_entries 16
  @max_chain_entry_bytes 128
  @max_join_inputs 256

  typedstruct enforce: true do
    field(:level, level(), default: :trusted)
    field(:sensitivity, sensitivity(), default: :internal)
    field(:sanitizations, non_neg_integer(), default: 0)
    field(:confidence, confidence(), default: :unverified)
    field(:source, String.t() | nil, default: nil)
    field(:chain, [String.t()], default: [])
  end

  @doc "Returns the exact process-local taint fields."
  @spec fields() :: [atom()]
  def fields, do: @taint_fields

  @doc "Returns the maximum source-label byte length."
  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_bytes

  @doc "Returns the maximum number of provenance-chain entries."
  @spec max_chain_entries() :: pos_integer()
  def max_chain_entries, do: @max_chain_entries

  @doc "Returns the maximum byte length of one provenance-chain entry."
  @spec max_chain_entry_bytes() :: pos_integer()
  def max_chain_entry_bytes, do: @max_chain_entry_bytes

  @doc "Returns the maximum number of taints accepted by one monotonic join."
  @spec max_join_inputs() :: pos_integer()
  def max_join_inputs, do: @max_join_inputs

  @doc "Returns the absorbing fail-closed durable-provenance taint."
  @spec invalid_durable_provenance() :: t()
  def invalid_durable_provenance do
    %__MODULE__{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: "invalid_durable_provenance",
      chain: []
    }
  end

  @doc "Constructs and validates an exact taint from atom-keyed attributes."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, normalized} <- exact_attributes(attrs),
         {:ok, taint} <- canonicalize(normalized) do
      {:ok, taint}
    end
  end

  def new(_attrs), do: {:error, :invalid_taint}

  @doc "Canonicalizes an exact taint struct or atom/string-keyed taint map."
  @spec canonicalize(term()) :: {:ok, t()} | {:error, atom()}
  def canonicalize(%__MODULE__{} = taint) do
    if exact_struct_shape?(taint), do: validate_and_return(taint), else: {:error, :invalid_taint}
  end

  def canonicalize(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, normalized} <- exact_attributes(attrs),
         {:ok, taint} <- normalize_attributes(normalized) do
      validate_and_return(taint)
    end
  end

  def canonicalize(_value), do: {:error, :invalid_taint}

  @doc "Validates an exact taint without exposing malformed input."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(value) do
    case canonicalize(value) do
      {:ok, _taint} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the monotonic join of two taints, or a bounded validation error."
  @spec join(term(), term()) :: {:ok, t()} | {:error, atom()}
  def join(left, right) do
    with {:ok, left} <- canonicalize(left),
         {:ok, right} <- canonicalize(right),
         result <- merge_provenance(left, right) do
      case result do
        {:invalid, invalid} ->
          {:ok, invalid}

        {:ok, source, chain} ->
          {:ok,
           %__MODULE__{
             level: max_by(levels(), left.level, right.level),
             sensitivity: max_by(sensitivities(), left.sensitivity, right.sensitivity),
             sanitizations: Bitwise.band(left.sanitizations, right.sanitizations),
             confidence: min_by(confidences(), left.confidence, right.confidence),
             source: source,
             chain: chain
           }}
      end
    end
  end

  @doc "Returns the bounded monotonic join of a non-empty proper list of taints."
  @spec join_many([term()]) :: {:ok, t()} | {:error, atom()}
  def join_many([]), do: {:error, :empty_taint_list}

  def join_many([first | rest]) do
    with {:ok, first} <- canonicalize(first) do
      join_many(rest, first, 1)
    end
  end

  def join_many(_values), do: {:error, :invalid_taint_list}

  @doc "Returns the exact string-keyed taint representation used by durable envelopes."
  @spec to_persisted(term()) :: {:ok, map()} | {:error, atom()}
  def to_persisted(value) do
    with {:ok, taint} <- canonicalize(value) do
      {:ok,
       %{
         "level" => Atom.to_string(taint.level),
         "sensitivity" => Atom.to_string(taint.sensitivity),
         "sanitizations" => taint.sanitizations,
         "confidence" => Atom.to_string(taint.confidence),
         "source" => taint.source,
         "chain" => taint.chain
       }}
    end
  end

  # ── Sanitization Constants ──────────────────────────────────────────

  @doc "Returns the sanitization bit positions map."
  @spec sanitization_bits() :: %{atom() => non_neg_integer()}
  def sanitization_bits, do: @sanitization_bits

  @doc "Returns the bit position for a named sanitization."
  @spec sanitization_bit(atom()) :: {:ok, non_neg_integer()} | :error
  def sanitization_bit(name) when is_atom(name) do
    case Map.fetch(@sanitization_bits, name) do
      {:ok, _bit} = ok -> ok
      :error -> :error
    end
  end

  # ── Ordering Constants ──────────────────────────────────────────────

  @doc "Returns valid levels in severity order (lowest to highest)."
  @spec levels() :: [level()]
  def levels, do: [:trusted, :derived, :untrusted, :hostile]

  @doc "Returns valid sensitivity levels in severity order."
  @spec sensitivities() :: [sensitivity()]
  def sensitivities, do: [:public, :internal, :confidential, :restricted]

  @doc "Returns valid confidence levels in certainty order."
  @spec confidences() :: [confidence()]
  def confidences, do: [:unverified, :plausible, :corroborated, :verified]

  defp exact_attributes(attrs) when is_map(attrs) and not is_struct(attrs) do
    if map_size(attrs) != length(@taint_fields) do
      {:error, :invalid_taint_shape}
    else
      keys = Map.keys(attrs)

      cond do
        Enum.all?(keys, &(&1 in @taint_fields)) ->
          {:ok, attrs}

        Enum.all?(keys, &(&1 in @string_taint_fields)) ->
          {:ok, Map.new(attrs, fn {key, value} -> {String.to_existing_atom(key), value} end)}

        true ->
          {:error, :invalid_taint_shape}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_taint_shape}
  end

  defp exact_attributes(attrs) when is_list(attrs) do
    collect_keyword(attrs, %{})
  end

  defp exact_attributes(_attrs), do: {:error, :invalid_taint_shape}

  defp collect_keyword([], attrs) when map_size(attrs) == length(@taint_fields), do: {:ok, attrs}
  defp collect_keyword([], _attrs), do: {:error, :invalid_taint_shape}

  defp collect_keyword([{key, value} | rest], attrs) when key in @taint_fields do
    if Map.has_key?(attrs, key),
      do: {:error, :invalid_taint_shape},
      else: collect_keyword(rest, Map.put(attrs, key, value))
  end

  defp collect_keyword(_attrs, _acc), do: {:error, :invalid_taint_shape}

  defp normalize_attributes(attrs) do
    with {:ok, level} <- normalize_enum(Map.fetch!(attrs, :level), levels()),
         {:ok, sensitivity} <- normalize_enum(Map.fetch!(attrs, :sensitivity), sensitivities()),
         {:ok, confidence} <- normalize_enum(Map.fetch!(attrs, :confidence), confidences()),
         {:ok, source} <- normalize_source(Map.fetch!(attrs, :source)),
         {:ok, chain} <- normalize_chain(Map.fetch!(attrs, :chain)) do
      {:ok,
       %__MODULE__{
         level: level,
         sensitivity: sensitivity,
         sanitizations: Map.fetch!(attrs, :sanitizations),
         confidence: confidence,
         source: source,
         chain: chain
       }}
    end
  end

  defp validate_and_return(%__MODULE__{} = taint) do
    if taint.level in levels() and taint.sensitivity in sensitivities() and
         is_integer(taint.sanitizations) and taint.sanitizations in 0..255 and
         taint.confidence in confidences() and valid_source?(taint.source) and
         valid_chain?(taint.chain) do
      {:ok, taint}
    else
      {:error, :invalid_taint}
    end
  end

  defp normalize_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_taint}
  end

  defp normalize_enum(value, allowed) when is_binary(value) do
    atom = Enum.find(allowed, &(Atom.to_string(&1) == value))
    if atom, do: {:ok, atom}, else: {:error, :invalid_taint}
  end

  defp normalize_enum(_value, _allowed), do: {:error, :invalid_taint}

  defp normalize_source(nil), do: {:ok, nil}
  defp normalize_source(value) when is_binary(value), do: {:ok, value}
  defp normalize_source(_value), do: {:error, :invalid_taint}

  defp normalize_chain(value) when is_list(value), do: {:ok, value}
  defp normalize_chain(_value), do: {:error, :invalid_taint}

  defp valid_source?(nil), do: true

  defp valid_source?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_source_bytes and String.valid?(value) and
        String.trim(value) != ""

  defp valid_chain?(chain) when is_list(chain), do: valid_chain?(chain, @max_chain_entries)

  defp valid_chain?(_chain), do: false

  defp valid_chain?([], _remaining), do: true

  defp valid_chain?([entry | rest], remaining) when remaining > 0 do
    is_binary(entry) and byte_size(entry) <= @max_chain_entry_bytes and String.valid?(entry) and
      String.trim(entry) != "" and valid_chain?(rest, remaining - 1)
  end

  defp valid_chain?(_chain, _remaining), do: false

  defp exact_struct_shape?(%__MODULE__{} = taint) do
    map_size(taint) == length(@taint_fields) + 1 and
      Enum.sort(Map.keys(taint)) == Enum.sort([:__struct__ | @taint_fields])
  end

  defp max_by(order, left, right) do
    if Enum.find_index(order, &(&1 == left)) >= Enum.find_index(order, &(&1 == right)),
      do: left,
      else: right
  end

  defp min_by(order, left, right) do
    if Enum.find_index(order, &(&1 == left)) <= Enum.find_index(order, &(&1 == right)),
      do: left,
      else: right
  end

  defp merge_provenance(left, right) do
    if invalid_durable?(left) or invalid_durable?(right) do
      {:invalid, invalid_durable_provenance()}
    else
      merge_provenance_labels(left, right)
    end
  end

  defp merge_provenance_labels(left, right) do
    if left == right do
      {:ok, left.source, left.chain}
    else
      labels =
        [left.source, right.source | left.chain ++ right.chain]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      if valid_provenance_labels?(labels) do
        case labels do
          [] -> {:ok, nil, []}
          [source | chain] -> {:ok, source, chain}
        end
      else
        {:invalid, invalid_durable_provenance()}
      end
    end
  end

  defp valid_provenance_labels?([]), do: true

  defp valid_provenance_labels?([source | chain]) do
    valid_source?(source) and valid_chain?(chain)
  end

  defp invalid_durable?(%__MODULE__{
         level: :hostile,
         sensitivity: :restricted,
         sanitizations: 0,
         confidence: :unverified,
         source: "invalid_durable_provenance",
         chain: []
       }),
       do: true

  defp invalid_durable?(_taint), do: false

  defp join_many([], acc, _count), do: {:ok, acc}

  defp join_many([_next | _rest], _acc, @max_join_inputs),
    do: {:error, :taint_join_limit_exceeded}

  defp join_many([next | rest], acc, count) when count < @max_join_inputs do
    with {:ok, joined} <- join(acc, next) do
      join_many(rest, joined, count + 1)
    end
  end

  defp join_many(_improper_tail, _acc, _count), do: {:error, :invalid_taint_list}
end

defimpl Jason.Encoder, for: Arbor.Contracts.Security.Taint do
  alias Arbor.Contracts.Security.Taint

  def encode(taint, opts) do
    case Taint.to_persisted(taint) do
      {:ok, persisted} ->
        Jason.Encode.map(persisted, opts)

      {:error, _reason} ->
        raise Protocol.UndefinedError,
          protocol: Jason.Encoder,
          value: taint,
          description: "invalid taint cannot be encoded"
    end
  end
end
