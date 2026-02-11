defmodule Arbor.Contracts.Checkpoint do
  @moduledoc """
  TypedStruct for unified checkpoint envelope.

  A checkpoint captures point-in-time state from any source (engine, session,
  event log, or custom) into a single, serializable envelope with HMAC integrity,
  retention policy, and privacy classification.

  ## Source Types

  - `:engine` — DOT behavioral engine checkpoint
  - `:session` — Agent session state snapshot
  - `:event_log` — Event log snapshotter output
  - `:custom` — Application-defined checkpoint

  ## Retention Policies

  - `{:ttl, hours}` — Expire after N hours (default: 24)
  - `{:count, n}` — Keep last N checkpoints per source
  - `:permanent` — Never expire
  - `:ephemeral` — Discard on process exit (in-memory only)

  ## Classification

  Uses the same four-level privacy model as `Arbor.Contracts.Signal.Event`:

  | Level | Description |
  |-------|-------------|
  | `:public` | Safe to log/export |
  | `:internal` | Internal context (default) |
  | `:sensitive` | PII or user-specific data |
  | `:restricted` | Highest classification |

  ## HMAC Integrity

  The optional `hmac` field holds an HMAC digest of the serialized `data`
  payload. When present, consumers MUST verify integrity before restoring.
  The HMAC is excluded from JSON serialization to avoid leaking key material.

  ## Chaining

  Checkpoints form a linked list via `parent_id`. Use `chain/2` to create a
  child checkpoint that inherits `source_type`, `source_id`, and increments
  `version`.

  ## Usage

      {:ok, cp} = Checkpoint.new(
        source_type: :session,
        source_id: "session_abc123",
        data: %{turn_count: 5, phase: :idle}
      )

      Checkpoint.expired?(cp)  # => false (within 24-hour TTL)

      {:ok, child} = Checkpoint.chain(cp, %{turn_count: 6, phase: :processing})
      child.parent_id == cp.id  # => true
      child.version == 2        # => true
  """

  use TypedStruct

  @valid_source_types [:engine, :session, :event_log, :custom]
  @valid_classifications [:public, :internal, :sensitive, :restricted]

  @derive {Jason.Encoder, except: [:hmac]}
  typedstruct enforce: true do
    @typedoc "A unified checkpoint envelope"

    # Identity
    field(:id, String.t())
    field(:source_type, :engine | :session | :event_log | :custom)
    field(:source_id, String.t())
    field(:timestamp, DateTime.t())

    # Versioning & chaining
    field(:version, pos_integer(), default: 1)
    field(:parent_id, String.t() | nil, enforce: false)

    # Integrity
    field(:hmac, binary() | nil, enforce: false)

    # Lifecycle
    field(:retention_policy,
      {:ttl, pos_integer()} | {:count, pos_integer()} | :permanent | :ephemeral,
      default: {:ttl, 24}
    )

    # Privacy
    field(:classification, :public | :internal | :sensitive | :restricted, default: :internal)

    # Payload
    field(:data, map())
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new checkpoint with validation.

  Generates a unique `id` and sets `timestamp` to `DateTime.utc_now/0`
  if not provided.

  ## Required Fields

  - `:source_type` — One of `:engine`, `:session`, `:event_log`, `:custom`
  - `:source_id` — Identifier for the checkpoint source
  - `:data` — Opaque payload map

  ## Optional Fields

  - `:id` — Override the generated ID
  - `:timestamp` — Override the timestamp (default: `DateTime.utc_now/0`)
  - `:version` — Version number (default: `1`)
  - `:parent_id` — ID of the parent checkpoint in a chain
  - `:hmac` — HMAC digest of the serialized data
  - `:retention_policy` — Lifecycle policy (default: `{:ttl, 24}`)
  - `:classification` — Privacy level (default: `:internal`)
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, cp} = Checkpoint.new(
        source_type: :session,
        source_id: "session_abc123",
        data: %{turn_count: 5}
      )

      {:error, {:missing_required, :source_type}} = Checkpoint.new(
        source_id: "x",
        data: %{}
      )

      {:error, {:invalid_source_type, :bogus}} = Checkpoint.new(
        source_type: :bogus,
        source_id: "x",
        data: %{}
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required_string(attrs, :source_id),
         :ok <- validate_source_type(get_attr(attrs, :source_type)),
         :ok <- validate_required_map(attrs, :data),
         :ok <- validate_classification(get_attr(attrs, :classification)),
         :ok <- validate_retention_policy(get_attr(attrs, :retention_policy)),
         :ok <- validate_optional_string(attrs, :parent_id),
         :ok <- validate_optional_pos_integer(attrs, :version),
         :ok <- validate_optional_map(attrs, :metadata) do
      checkpoint = %__MODULE__{
        id: get_attr(attrs, :id) || generate_id(),
        source_type: get_attr(attrs, :source_type),
        source_id: get_attr(attrs, :source_id),
        timestamp: get_attr(attrs, :timestamp) || DateTime.utc_now(),
        version: get_attr(attrs, :version) || 1,
        parent_id: get_attr(attrs, :parent_id),
        hmac: get_attr(attrs, :hmac),
        retention_policy: get_attr(attrs, :retention_policy) || {:ttl, 24},
        classification: get_attr(attrs, :classification) || :internal,
        data: get_attr(attrs, :data),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, checkpoint}
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Returns `true` if the checkpoint has expired according to its retention policy.

  Accepts an optional `now` parameter for testing; defaults to `DateTime.utc_now/0`.

  ## Retention Semantics

  - `{:ttl, hours}` — Expired if `now - timestamp >= hours`
  - `{:count, _n}` — Never expired by time alone (count-based pruning is external)
  - `:permanent` — Never expired
  - `:ephemeral` — Always expired (should not survive process boundaries)

  ## Examples

      {:ok, cp} = Checkpoint.new(
        source_type: :session,
        source_id: "s1",
        data: %{},
        retention_policy: {:ttl, 1}
      )

      Checkpoint.expired?(cp)  # => false (just created)

      two_hours_later = DateTime.add(DateTime.utc_now(), 2, :hour)
      Checkpoint.expired?(cp, two_hours_later)  # => true

      {:ok, perm} = Checkpoint.new(
        source_type: :session,
        source_id: "s1",
        data: %{},
        retention_policy: :permanent
      )
      Checkpoint.expired?(perm)  # => false (never expires)
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(checkpoint, now \\ DateTime.utc_now())

  def expired?(%__MODULE__{retention_policy: :permanent}, _now), do: false

  def expired?(%__MODULE__{retention_policy: :ephemeral}, _now), do: true

  def expired?(%__MODULE__{retention_policy: {:count, _n}}, _now), do: false

  def expired?(%__MODULE__{retention_policy: {:ttl, hours}, timestamp: timestamp}, now) do
    diff_seconds = DateTime.diff(now, timestamp, :second)
    diff_seconds >= hours * 3600
  end

  # ============================================================================
  # Chaining
  # ============================================================================

  @doc """
  Create a child checkpoint chained from a parent.

  The child inherits `source_type` and `source_id`, increments `version`,
  and sets `parent_id` to the parent's `id`. A new `id` and `timestamp`
  are generated.

  ## Parameters

  - `parent` — The parent checkpoint to chain from
  - `data` — New data payload for the child

  ## Options

  - `:metadata` — Override metadata (default: `%{}`)
  - `:classification` — Override classification (default: inherits parent)
  - `:retention_policy` — Override retention (default: inherits parent)

  ## Examples

      {:ok, parent} = Checkpoint.new(
        source_type: :engine,
        source_id: "engine_1",
        data: %{step: 1}
      )

      {:ok, child} = Checkpoint.chain(parent, %{step: 2})
      child.parent_id == parent.id     # => true
      child.version == 2               # => true
      child.source_type == :engine     # => true
      child.source_id == "engine_1"    # => true
  """
  @spec chain(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def chain(%__MODULE__{} = parent, data, opts \\ []) when is_map(data) do
    new(
      source_type: parent.source_type,
      source_id: parent.source_id,
      parent_id: parent.id,
      version: parent.version + 1,
      data: data,
      classification: Keyword.get(opts, :classification, parent.classification),
      retention_policy: Keyword.get(opts, :retention_policy, parent.retention_policy),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_source_type(nil), do: {:error, {:missing_required, :source_type}}

  defp validate_source_type(type) when type in @valid_source_types, do: :ok

  defp validate_source_type(type), do: {:error, {:invalid_source_type, type}}

  defp validate_classification(nil), do: :ok

  defp validate_classification(c) when c in @valid_classifications, do: :ok

  defp validate_classification(c), do: {:error, {:invalid_classification, c}}

  defp validate_retention_policy(nil), do: :ok
  defp validate_retention_policy(:permanent), do: :ok
  defp validate_retention_policy(:ephemeral), do: :ok

  defp validate_retention_policy({:ttl, hours}) when is_integer(hours) and hours > 0, do: :ok

  defp validate_retention_policy({:count, n}) when is_integer(n) and n > 0, do: :ok

  defp validate_retention_policy(policy), do: {:error, {:invalid_retention_policy, policy}}

  defp validate_required_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      val when is_binary(val) and byte_size(val) > 0 -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_required_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      val when is_map(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_pos_integer(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_integer(val) and val > 0 -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  defp validate_optional_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      val -> {:error, {:"invalid_#{key}", val}}
    end
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp generate_id do
    "cp_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
