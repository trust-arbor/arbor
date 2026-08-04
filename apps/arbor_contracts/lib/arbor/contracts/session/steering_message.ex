defmodule Arbor.Contracts.Session.SteeringMessage do
  @moduledoc """
  Closed, source-owned message accepted as steering for an active turn.

  The envelope intentionally carries only message identity, engagement routing,
  content, and provenance. Authority, caller, timestamp, turn-token, and
  transport metadata belong to the process-local Session boundary and are not
  admitted here.

  The 32,768-byte content ceiling and 256-byte engagement-id ceiling reuse the
  existing public Agent ingress limits. Taint source and chain limits are named,
  reversible resource policy: 128 bytes per provenance label and 16 chain
  entries keep one steering envelope bounded without defining a wire protocol.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.Taint

  @max_content_bytes 32_768
  @max_engagement_id_bytes 256
  @max_taint_source_bytes 128
  @max_taint_chain_entries 16
  @max_taint_chain_entry_bytes 128

  @message_id_bytes byte_size("steer_") + 32
  @message_id_pattern ~r/\Asteer_[0-9a-f]{32}\z/
  @engagement_id_pattern ~r/\Aeng_[0-9a-f]{32}\z/
  @fields [:message_id, :engagement_id, :content, :taint]
  @taint_fields [
    :level,
    :sensitivity,
    :sanitizations,
    :confidence,
    :source,
    :chain
  ]

  typedstruct enforce: true do
    @typedoc "A bounded steering message for one source-owned engagement"

    field(:message_id, String.t())
    field(:engagement_id, String.t() | nil)
    field(:content, String.t())
    field(:taint, Taint.t())
  end

  @doc "Returns the public Agent ingress content ceiling reused by steering."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @doc "Returns the existing engagement identifier byte ceiling."
  @spec max_engagement_id_bytes() :: pos_integer()
  def max_engagement_id_bytes, do: @max_engagement_id_bytes

  @doc "Returns the reversible per-source taint provenance ceiling."
  @spec max_taint_source_bytes() :: pos_integer()
  def max_taint_source_bytes, do: @max_taint_source_bytes

  @doc "Returns the reversible maximum number of taint chain entries."
  @spec max_taint_chain_entries() :: pos_integer()
  def max_taint_chain_entries, do: @max_taint_chain_entries

  @doc "Returns the reversible byte ceiling for each taint chain entry."
  @spec max_taint_chain_entry_bytes() :: pos_integer()
  def max_taint_chain_entry_bytes, do: @max_taint_chain_entry_bytes

  @doc """
  Construct a steering message from exactly four atom-keyed attributes.

  Missing, extra, duplicate, string-keyed, malformed, or unbounded attributes
  fail closed. The constructor never rewrites caller-provided identifiers or
  content.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) do
    with {:ok, normalized} <- exact_attributes(attrs),
         :ok <- validate_message_id(normalized.message_id),
         :ok <- validate_engagement_id(normalized.engagement_id),
         :ok <- validate_content(normalized.content),
         :ok <- validate_taint(normalized.taint) do
      {:ok,
       %__MODULE__{
         message_id: normalized.message_id,
         engagement_id: normalized.engagement_id,
         content: normalized.content,
         taint: normalized.taint
       }}
    end
  end

  @doc """
  Canonicalize a term into an exact, validated steering-message struct.

  Struct-tagged maps are checked for the complete struct shape before safe field
  extraction, so forged partial or extended structs cannot cross the boundary.
  """
  @spec canonicalize(term()) :: {:ok, t()} | {:error, atom()}
  def canonicalize(%__MODULE__{} = message) do
    if exact_struct_shape?(message, __MODULE__, @fields) do
      new(%{
        message_id: Map.get(message, :message_id),
        engagement_id: Map.get(message, :engagement_id),
        content: Map.get(message, :content),
        taint: Map.get(message, :taint)
      })
    else
      {:error, :invalid_message_shape}
    end
  end

  def canonicalize(attrs) when is_map(attrs) or is_list(attrs), do: new(attrs)
  def canonicalize(_), do: {:error, :invalid_steering_message}

  defp exact_attributes(attrs) when is_map(attrs) and not is_struct(attrs) do
    if map_size(attrs) == length(@fields) and
         Enum.sort(Map.keys(attrs)) == Enum.sort(@fields) do
      {:ok, attrs}
    else
      {:error, :invalid_attributes}
    end
  end

  defp exact_attributes(attrs) when is_list(attrs), do: exact_keyword(attrs, %{})
  defp exact_attributes(_), do: {:error, :invalid_attributes}

  defp exact_keyword([], attrs) when map_size(attrs) == length(@fields), do: {:ok, attrs}
  defp exact_keyword([], _attrs), do: {:error, :invalid_attributes}

  defp exact_keyword([{key, value} | rest], attrs)
       when key in @fields and not is_map_key(attrs, key) do
    exact_keyword(rest, Map.put(attrs, key, value))
  end

  defp exact_keyword(_improper_or_invalid, _attrs), do: {:error, :invalid_attributes}

  defp validate_message_id(value) when is_binary(value) do
    if byte_size(value) == @message_id_bytes and Regex.match?(@message_id_pattern, value),
      do: :ok,
      else: {:error, :invalid_message_id}
  end

  defp validate_message_id(_), do: {:error, :invalid_message_id}

  defp validate_engagement_id(nil), do: :ok

  defp validate_engagement_id(value) when is_binary(value) do
    if byte_size(value) <= @max_engagement_id_bytes and
         Regex.match?(@engagement_id_pattern, value) do
      :ok
    else
      {:error, :invalid_engagement_id}
    end
  end

  defp validate_engagement_id(_), do: {:error, :invalid_engagement_id}

  defp validate_content(value) when is_binary(value) do
    if byte_size(value) <= @max_content_bytes and String.valid?(value) and
         String.trim(value) != "" do
      :ok
    else
      {:error, :invalid_content}
    end
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_taint(%Taint{} = taint) do
    with true <- exact_struct_shape?(taint, Taint, @taint_fields),
         true <- taint.level in Taint.levels(),
         true <- taint.sensitivity in Taint.sensitivities(),
         true <- taint.confidence in Taint.confidences(),
         true <- is_integer(taint.sanitizations) and taint.sanitizations in 0..255,
         true <- valid_optional_label?(taint.source, @max_taint_source_bytes),
         true <- valid_chain?(taint.chain) do
      :ok
    else
      _ -> {:error, :invalid_taint}
    end
  end

  defp validate_taint(_), do: {:error, :invalid_taint}

  defp valid_optional_label?(nil, _max_bytes), do: true

  defp valid_optional_label?(value, max_bytes), do: valid_label?(value, max_bytes)

  defp valid_label?(value, max_bytes) when is_binary(value) do
    byte_size(value) <= max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_label?(_value, _max_bytes), do: false

  defp valid_chain?(chain), do: valid_chain?(chain, @max_taint_chain_entries)

  defp valid_chain?([], _remaining), do: true

  defp valid_chain?([entry | rest], remaining) when remaining > 0 do
    valid_label?(entry, @max_taint_chain_entry_bytes) and valid_chain?(rest, remaining - 1)
  end

  defp valid_chain?(_too_long_or_improper, _remaining), do: false

  defp exact_struct_shape?(value, module, fields) when is_map(value) do
    map_size(value) == length(fields) + 1 and Map.get(value, :__struct__) == module and
      Enum.sort(Map.keys(value)) == Enum.sort([:__struct__ | fields])
  end

  defp exact_struct_shape?(_value, _module, _fields), do: false
end
