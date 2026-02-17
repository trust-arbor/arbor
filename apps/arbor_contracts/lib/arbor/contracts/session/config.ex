defmodule Arbor.Contracts.Session.Config do
  @moduledoc """
  TypedStruct for immutable session configuration.

  Created once at session start, never mutated during the session lifecycle.
  All per-turn mutable state lives in the Engine context map — this struct
  captures the invariants that hold for the entire session.

  ## Session Types

  - `:primary` — Interactive user-facing session (default)
  - `:background` — Autonomous background work (heartbeat, maintenance)
  - `:delegation` — Spawned by another session to handle a sub-task
  - `:consultation` — Advisory council or peer query

  ## Delegation

  Use `delegation/2` to spawn a child session that inherits the parent's
  agent identity, trust tier, and resource budget while getting its own
  session ID and allowing overrides.

  ## Usage

      {:ok, config} = Config.new(
        session_id: "sess_abc123",
        agent_id: "agent_def456",
        trust_tier: :established
      )

      {:ok, child} = Config.delegation(config,
        session_id: "sess_child_789",
        session_type: :consultation,
        max_tool_iterations: 3
      )
  """

  use TypedStruct

  alias Arbor.Contracts.AI.ResourceBudget

  @valid_session_types [:primary, :background, :delegation, :consultation]

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "Immutable session configuration, created once at session start"

    field(:session_id, String.t())
    field(:agent_id, String.t())
    field(:trust_tier, atom())
    field(:session_type, :primary | :background | :delegation | :consultation, default: :primary)
    field(:parent_session_id, String.t() | nil, enforce: false)
    field(:graph_ref, String.t() | nil, enforce: false)
    field(:resource_budget, ResourceBudget.t() | nil, enforce: false)
    field(:max_messages, pos_integer() | nil, enforce: false)
    field(:max_tool_iterations, pos_integer(), default: 10)
    field(:schema_version, pos_integer(), default: 1)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new session config with validation.

  Accepts a keyword list or map. Required fields: `session_id`, `agent_id`,
  `trust_tier`.

  ## Options

  - `:session_id` — Unique session identifier (required, non-empty string)
  - `:agent_id` — Agent owning this session (required, non-empty string)
  - `:trust_tier` — Agent's trust tier (required, atom)
  - `:session_type` — Session purpose (default: `:primary`)
  - `:parent_session_id` — ID of the parent session for delegations
  - `:graph_ref` — Reference to the DOT graph driving this session
  - `:resource_budget` — `ResourceBudget.t()` constraining resource usage
  - `:max_messages` — Maximum messages before compaction/termination
  - `:max_tool_iterations` — Maximum tool loop iterations per turn (default: 10)
  - `:schema_version` — Config schema version for forward compatibility (default: 1)
  - `:metadata` — Arbitrary metadata map (default: `%{}`)

  ## Examples

      {:ok, config} = Config.new(
        session_id: "sess_001",
        agent_id: "agent_abc",
        trust_tier: :established
      )

      {:error, {:missing_required, :session_id}} = Config.new(agent_id: "x", trust_tier: :new)

      {:error, {:invalid_session_type, :bogus}} = Config.new(
        session_id: "s", agent_id: "a", trust_tier: :new, session_type: :bogus
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required_string(attrs, :session_id),
         :ok <- validate_required_string(attrs, :agent_id),
         :ok <- validate_required_atom(attrs, :trust_tier),
         :ok <- validate_session_type(get_attr(attrs, :session_type)),
         :ok <- validate_optional_string(attrs, :parent_session_id),
         :ok <- validate_optional_string(attrs, :graph_ref),
         :ok <- validate_resource_budget(get_attr(attrs, :resource_budget)),
         :ok <- validate_pos_integer_or_nil(attrs, :max_messages),
         :ok <- validate_pos_integer_or_nil(attrs, :max_tool_iterations),
         :ok <- validate_pos_integer_or_nil(attrs, :schema_version),
         :ok <- validate_metadata(get_attr(attrs, :metadata)) do
      config = %__MODULE__{
        session_id: get_attr(attrs, :session_id),
        agent_id: get_attr(attrs, :agent_id),
        trust_tier: get_attr(attrs, :trust_tier),
        session_type: get_attr(attrs, :session_type) || :primary,
        parent_session_id: get_attr(attrs, :parent_session_id),
        graph_ref: get_attr(attrs, :graph_ref),
        resource_budget: get_attr(attrs, :resource_budget),
        max_messages: get_attr(attrs, :max_messages),
        max_tool_iterations: get_attr(attrs, :max_tool_iterations) || 10,
        schema_version: get_attr(attrs, :schema_version) || 1,
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, config}
    end
  end

  @doc """
  Creates a delegation config from a parent config with overrides.

  The child inherits the parent's `agent_id`, `trust_tier`, and
  `resource_budget`. The caller must provide a new `session_id`.
  `parent_session_id` is set automatically. `session_type` defaults
  to `:delegation` but can be overridden (e.g., to `:consultation`).

  ## Examples

      {:ok, parent} = Config.new(
        session_id: "sess_parent",
        agent_id: "agent_abc",
        trust_tier: :established
      )

      {:ok, child} = Config.delegation(parent,
        session_id: "sess_child",
        max_tool_iterations: 3
      )

      child.parent_session_id  # => "sess_parent"
      child.agent_id           # => "agent_abc"
      child.session_type       # => :delegation

      {:error, {:missing_required, :session_id}} = Config.delegation(parent, [])
  """
  @spec delegation(t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def delegation(%__MODULE__{} = parent, overrides) when is_list(overrides) do
    delegation(parent, Map.new(overrides))
  end

  def delegation(%__MODULE__{} = parent, overrides) when is_map(overrides) do
    attrs =
      %{
        agent_id: parent.agent_id,
        trust_tier: parent.trust_tier,
        resource_budget: parent.resource_budget,
        session_type: :delegation,
        parent_session_id: parent.session_id,
        schema_version: parent.schema_version
      }
      |> Map.merge(overrides)

    new(attrs)
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_required_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      val when is_binary(val) and byte_size(val) > 0 -> :ok
      "" -> {:error, {:missing_required, key}}
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_required_atom(attrs, key) do
    case get_attr(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      val when is_atom(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_session_type(nil), do: :ok

  defp validate_session_type(type) when type in @valid_session_types, do: :ok

  defp validate_session_type(type), do: {:error, {:invalid_session_type, type}}

  defp validate_resource_budget(nil), do: :ok

  defp validate_resource_budget(%ResourceBudget{}), do: :ok

  defp validate_resource_budget(invalid), do: {:error, {:invalid_resource_budget, invalid}}

  defp validate_pos_integer_or_nil(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      n when is_integer(n) and n > 0 -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_metadata(nil), do: :ok

  defp validate_metadata(meta) when is_map(meta), do: :ok

  defp validate_metadata(invalid), do: {:error, {:invalid_metadata, invalid}}

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
