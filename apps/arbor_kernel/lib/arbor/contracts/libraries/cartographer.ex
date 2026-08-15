defmodule Arbor.Contracts.Libraries.Cartographer do
  @moduledoc """
  Public API contract for the Arbor.Cartographer library.

  This contract defines the facade interface for capability-based hardware
  scheduling. Arbor.Cartographer provides:

  - **Hardware Introspection** - Auto-detect GPU, memory, architecture
  - **Capability Registration** - Nodes advertise their capabilities
  - **Smart Scheduling** - Deploy agents to capable nodes
  - **Load Balancing** - Select least-loaded matching nodes
  - **Affinity Rules** - Keep related agents together (or apart)

  Built on top of [eigr/mesh](https://github.com/eigr/mesh) for capability-based
  routing with Arbor-specific hardware introspection.

  ## Quick Start

      # Start the cartographer (runs Scout on each node)
      {:ok, _} = Arbor.Cartographer.start_link()

      # Deploy an agent to a node with GPU
      {:ok, pid} = Arbor.Cartographer.deploy(MyLLMAgent,
        needs: [:gpu, :high_memory],
        args: [model: "llama-3-70b"]
      )

      # Query available capabilities
      {:ok, nodes} = Arbor.Cartographer.find_capable_nodes([:gpu])

  ## Capability Types

  | Type | Source | Example |
  |------|--------|---------|
  | Hardware | Scout introspection | `:gpu`, `:arm64`, `:high_memory` |
  | Model | Configuration | `:has_llama`, `:has_claude_api` |
  | Custom | Manual registration | `:production`, `:staging` |

  ## Hardware Tags

  | Tag | Meaning | Detection |
  |-----|---------|-----------|
  | `:gpu` | Has GPU | nvidia-smi / rocm-smi |
  | `:gpu_vram_24gb` | 24GB+ VRAM | nvidia-smi query |
  | `:coral_tpu` | Coral TPU | /dev/apex_0 |
  | `:high_memory` | 32GB+ RAM | :erlang.memory |
  | `:x86_64` | Intel/AMD | :system_architecture |
  | `:arm64` | ARM | :system_architecture |

  ## Integration with Arbor.Security

  Deployment can require security authorization:

      {:ok, pid} = Arbor.Cartographer.deploy(MyAgent,
        needs: [:gpu],
        security: %{principal_id: "agent_001"}
      )

  This checks both hardware capability AND security authorization.

  @version "1.0.0"

  ## Implementation Status

  **Note:** This contract is comprehensive but aspirational. Implementation
  depends on evaluating [eigr/mesh](https://github.com/eigr/mesh) for
  capability-based routing. All callbacks are marked as optional until
  implementation begins.

  See `.arbor/roadmap/0-inbox/backlog/2026-01-14-swarm-cartographer.md` for
  the detailed vision and implementation plan.
  """

  # ===========================================================================
  # Types
  # ===========================================================================

  @type capability_tag :: atom()
  @type node_id :: atom()
  @type affinity_label :: atom()
  @type load_score :: float()

  @type requirement ::
          capability_tag()
          | {:prefer, capability_tag()}
          | {:avoid, capability_tag()}

  @type deploy_opts :: [
          needs: [requirement()],
          prefers: [requirement()],
          affinity: affinity_label() | nil,
          anti_affinity: affinity_label() | nil,
          args: keyword(),
          security: map() | nil
        ]

  @type node_capabilities :: %{
          node: node_id(),
          tags: [capability_tag()],
          hardware: hardware_info(),
          load: load_score(),
          registered_at: DateTime.t()
        }

  @type hardware_info :: %{
          arch: :x86_64 | :arm64 | :arm32 | :unknown,
          cpus: non_neg_integer(),
          memory_gb: float(),
          gpu: [gpu_info()] | nil,
          accelerators: [accelerator_info()]
        }

  @type gpu_info :: %{
          type: :nvidia | :amd | :intel,
          name: String.t(),
          vram_gb: float()
        }

  @type accelerator_info :: %{
          type: :coral_tpu | :intel_ncs | atom(),
          device: String.t() | nil
        }

  @type deployment_result ::
          {:ok, pid()}
          | {:error, :no_capable_nodes}
          | {:error, :unauthorized}
          | {:error, term()}

  # ===========================================================================
  # Deployment
  # ===========================================================================

  @doc """
  Deploy an agent to a capable node.

  Finds the best node matching the requirements and starts the agent there.

  ## Parameters

  - `agent_module` - The agent module to start
  - `opts` - Deployment options

  ## Options

  - `:needs` - List of required capabilities (hard requirements)
  - `:prefers` - List of preferred capabilities (soft requirements)
  - `:affinity` - Place near other agents with this label
  - `:anti_affinity` - Place away from agents with this label
  - `:args` - Arguments passed to the agent
  - `:security` - Security context for authorization check

  ## Node Selection

  1. Filter nodes by hard requirements (`:needs`)
  2. Score remaining nodes by:
     - Soft requirement matches (`:prefers`)
     - Current load (prefer less loaded)
     - Affinity score
  3. Select highest scoring node

  ## Examples

      # Simple deployment with GPU requirement
      {:ok, pid} = Arbor.Cartographer.deploy(MyLLMAgent,
        needs: [:gpu]
      )

      # With soft preferences
      {:ok, pid} = Arbor.Cartographer.deploy(MyAgent,
        needs: [:gpu],
        prefers: [:high_memory, :fast_storage]
      )

      # Keep agents together
      {:ok, pid} = Arbor.Cartographer.deploy(MyAgent,
        needs: [:gpu],
        affinity: :llm_cluster
      )

      # With security authorization
      {:ok, pid} = Arbor.Cartographer.deploy(MyAgent,
        needs: [:gpu],
        security: %{principal_id: "agent_001"}
      )
  """
  @callback deploy(agent_module :: module(), deploy_opts()) :: deployment_result()

  @doc """
  Deploy to a specific node.

  Bypasses capability matching and deploys directly to the specified node.
  Still checks that the node is registered and (optionally) authorized.
  """
  @callback deploy_to_node(agent_module :: module(), node_id(), opts :: keyword()) ::
              {:ok, pid()} | {:error, :node_not_found | :unauthorized | term()}

  # ===========================================================================
  # Capability Queries
  # ===========================================================================

  @doc """
  Find nodes with all specified capabilities.

  ## Options

  - `:min_load` - Minimum acceptable load score
  - `:max_load` - Maximum acceptable load score
  - `:limit` - Max nodes to return

  ## Examples

      {:ok, nodes} = Arbor.Cartographer.find_capable_nodes([:gpu, :high_memory])
      #=> [:"node1@host", :"node2@host"]
  """
  @callback find_capable_nodes([capability_tag()], opts :: keyword()) ::
              {:ok, [node_id()]} | {:error, term()}

  @doc """
  Get capabilities of a specific node.
  """
  @callback get_node_capabilities(node_id()) ::
              {:ok, node_capabilities()} | {:error, :not_found}

  @doc """
  Get capabilities of all registered nodes.
  """
  @callback list_all_capabilities() :: {:ok, [node_capabilities()]}

  @doc """
  Get nodes that have a specific tag.
  """
  @callback nodes_with_tag(capability_tag()) :: {:ok, [node_id()]}

  @doc """
  Check if a node has specific capabilities.
  """
  @callback node_has_capabilities?(node_id(), [capability_tag()]) :: boolean()

  # ===========================================================================
  # Capability Registration
  # ===========================================================================

  @doc """
  Register capabilities for the current node.

  Called automatically by the Scout agent, but can be called manually
  to add custom capabilities.

  ## Examples

      # Add custom tags
      :ok = Arbor.Cartographer.register_capabilities([:production, :gpu_optimized])
  """
  @callback register_capabilities([capability_tag()]) :: :ok | {:error, term()}

  @doc """
  Unregister capabilities from the current node.
  """
  @callback unregister_capabilities([capability_tag()]) :: :ok

  @doc """
  Get the current node's registered capabilities.
  """
  @callback my_capabilities() :: {:ok, [capability_tag()]}

  # ===========================================================================
  # Load Monitoring
  # ===========================================================================

  @doc """
  Get the current load score for a node.

  Load is a weighted combination of CPU and memory pressure (0-100).
  """
  @callback get_node_load(node_id()) :: {:ok, load_score()} | {:error, :not_found}

  @doc """
  Get load scores for all nodes.
  """
  @callback get_all_loads() :: {:ok, %{node_id() => load_score()}}

  @doc """
  Update the load score for the current node.

  Called automatically by the Scout, but can be triggered manually.
  """
  @callback update_load() :: :ok

  # ===========================================================================
  # Hardware Introspection
  # ===========================================================================

  @doc """
  Detect hardware capabilities of the current node.

  Returns detailed hardware info including:
  - Architecture (x86_64, arm64)
  - CPU count
  - Memory
  - GPUs
  - Accelerators (TPU, NCS)
  """
  @callback detect_hardware() :: {:ok, hardware_info()}

  @doc """
  Detect available LLM models on the current node.

  Checks for:
  - Ollama models
  - API keys (Claude, OpenAI, Gemini)
  - Local model files
  """
  @callback detect_models() :: {:ok, [{:ollama | :api | :local, atom()}]}

  # ===========================================================================
  # Affinity Management
  # ===========================================================================

  @doc """
  Set an affinity label for an agent.

  Agents with the same affinity label will be preferentially placed
  on the same node.
  """
  @callback set_affinity(agent_pid :: pid(), affinity_label()) :: :ok

  @doc """
  Remove an affinity label from an agent.
  """
  @callback clear_affinity(agent_pid :: pid()) :: :ok

  @doc """
  Get all agents with a specific affinity label.
  """
  @callback agents_with_affinity(affinity_label()) :: {:ok, [pid()]}

  # ===========================================================================
  # Security Integration
  # ===========================================================================

  @doc """
  Check if an agent can be deployed with given requirements.

  Validates both:
  1. Hardware capability - A node with required capabilities exists
  2. Security authorization - Agent has permission to use the hardware

  ## Parameters

  - `principal_id` - Agent requesting deployment
  - `requirements` - Required capabilities
  """
  @callback authorize_deployment(principal_id :: String.t(), [capability_tag()]) ::
              {:ok, :authorized}
              | {:error, :no_capable_nodes}
              | {:error, :unauthorized}

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the Cartographer system.

  Starts the Scout agent for hardware introspection and registers
  with Mesh for capability-based routing.

  ## Options

  - `:introspection_interval` - How often to re-detect hardware (default: 5 min)
  - `:load_broadcast_interval` - How often to broadcast load (default: 30 sec)
  - `:mesh_adapter` - Mesh cluster adapter
  - `:security_enabled` - Enable security integration
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the Cartographer system is running and healthy.
  """
  @callback healthy?() :: boolean()

  @doc """
  Get the Scout agent for this node.
  """
  @callback get_scout() :: {:ok, pid()} | {:error, :not_running}

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  # NOTE: All callbacks are marked optional as implementation is pending.
  # Once implementation begins, core callbacks will be moved to required.
  @optional_callbacks [
    # Deployment
    deploy: 2,
    deploy_to_node: 3,
    # Capability queries
    find_capable_nodes: 2,
    get_node_capabilities: 1,
    list_all_capabilities: 0,
    nodes_with_tag: 1,
    node_has_capabilities?: 2,
    # Capability registration
    register_capabilities: 1,
    unregister_capabilities: 1,
    my_capabilities: 0,
    # Load monitoring
    get_node_load: 1,
    get_all_loads: 0,
    update_load: 0,
    # Hardware introspection
    detect_hardware: 0,
    detect_models: 0,
    # Affinity management
    set_affinity: 2,
    clear_affinity: 1,
    agents_with_affinity: 1,
    # Security integration
    authorize_deployment: 2,
    # Lifecycle
    start_link: 1,
    healthy?: 0,
    get_scout: 0
  ]
end
