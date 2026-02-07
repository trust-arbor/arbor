defmodule Arbor.Actions.MemoryCognitive do
  @moduledoc """
  Cognitive adjustment actions for tuning memory behavior.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `AdjustPreference` | Adjust cognitive preferences (decay rate, quotas, etc.) |
  | `PinMemory` | Pin important memories to protect from decay |
  | `UnpinMemory` | Unpin memories to allow normal decay |
  """

  # ============================================================================
  # AdjustPreference
  # ============================================================================

  defmodule AdjustPreference do
    @moduledoc """
    Adjust cognitive preferences.

    Parameters: decay_rate, max_pins, retrieval_threshold,
    consolidation_interval, attention_focus, type_quota.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `param` | string | yes | Parameter name to adjust |
    | `value` | any | yes | New value for the parameter |
    """

    use Jido.Action,
      name: "memory_adjust_preference",
      description:
        "Adjust cognitive preferences. Parameters: decay_rate (0.01-0.50), max_pins (1-200), retrieval_threshold (0.0-1.0), type_quota ({type, pct}). Required: param, value.",
      category: "memory_cognitive",
      tags: ["memory", "cognitive", "preferences", "adjust"],
      schema: [
        param: [type: :string, required: true, doc: "Parameter to adjust: decay_rate, max_pins, retrieval_threshold, etc."],
        value: [type: :any, required: true, doc: "New value for the parameter"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{param: :control, value: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           param_atom <- MemoryHelpers.safe_to_atom(params.param),
           {:ok, prefs} <- Arbor.Memory.adjust_preference(agent_id, param_atom, params.value) do
        Actions.emit_completed(__MODULE__, %{param: param_atom})

        {:ok,
         %{
           param: param_atom,
           value: params.value,
           adjusted: true,
           current: Arbor.Memory.Preferences.inspect_preferences(prefs)
         }}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # PinMemory
  # ============================================================================

  defmodule PinMemory do
    @moduledoc """
    Pin a memory to protect it from decay.

    Pinned memories maintain their relevance score even during consolidation.
    The number of pins is limited by the agent's trust level.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `node_id` | string | yes | Memory node ID to pin |
    | `reason` | string | no | Why this memory is important |
    """

    use Jido.Action,
      name: "memory_pin",
      description:
        "Pin a memory to protect from decay. Limited pins per trust level. Required: node_id. Optional: reason.",
      category: "memory_cognitive",
      tags: ["memory", "cognitive", "pin", "protect"],
      schema: [
        node_id: [type: :string, required: true, doc: "Memory node ID to pin"],
        reason: [type: :string, doc: "Why this memory is important"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{node_id: :data, reason: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           {:ok, _prefs} <- Arbor.Memory.pin_memory(agent_id, params.node_id) do
        Actions.emit_completed(__MODULE__, %{node_id: params.node_id})
        {:ok, %{node_id: params.node_id, pinned: true}}
      else
        {:error, :max_pins_reached} = error ->
          Actions.emit_failed(__MODULE__, :max_pins_reached)
          error

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # UnpinMemory
  # ============================================================================

  defmodule UnpinMemory do
    @moduledoc """
    Unpin a memory, allowing it to decay normally.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `node_id` | string | yes | Memory node ID to unpin |
    """

    use Jido.Action,
      name: "memory_unpin",
      description: "Unpin a memory, allowing normal decay. Required: node_id.",
      category: "memory_cognitive",
      tags: ["memory", "cognitive", "unpin"],
      schema: [
        node_id: [type: :string, required: true, doc: "Memory node ID to unpin"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{node_id: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           {:ok, _prefs} <- Arbor.Memory.unpin_memory(agent_id, params.node_id) do
        Actions.emit_completed(__MODULE__, %{node_id: params.node_id})
        {:ok, %{node_id: params.node_id, unpinned: true}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end
end
