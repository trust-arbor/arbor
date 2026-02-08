defmodule Arbor.Cartographer do
  @moduledoc """
  Hardware capability-aware scheduling for distributed Arbor agents.

  Arbor.Cartographer provides capability-based hardware scheduling for
  distributed agent deployment:

  - **Hardware Introspection** - Auto-detect GPU, memory, architecture
  - **Capability Registration** - Nodes advertise their capabilities
  - **Smart Scheduling** - Deploy agents to capable nodes
  - **Load Balancing** - Select least-loaded matching nodes
  - **Affinity Rules** - Keep related agents together (or apart)

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

  ## Current Implementation Status

  **Phase 1 (Complete):** Local-only operation
  - Hardware detection (CPU, memory, GPU, accelerators)
  - Local capability registration
  - Load monitoring

  **Phase 2 (Planned):** Basic deployment
  - Local deployment
  - Deployment to specific nodes

  **Phase 3 (Future):** Cluster integration
  - Multi-node capability queries
  - Load balancing across cluster
  - Mesh integration

  See `Arbor.Contracts.Libraries.Cartographer` for the full API contract.
  """

  @behaviour Arbor.Contracts.Libraries.Cartographer

  alias Arbor.Cartographer.{CapabilityRegistry, Hardware, Scout}

  # ==========================================================================
  # Deployment (Phase 2 - Planned)
  # ==========================================================================

  @doc """
  Deploy an agent to a capable node.

  Currently supports local deployment only. Cluster deployment will be added
  when mesh integration is complete.
  """
  @impl true
  def deploy(agent_module, opts \\ []) do
    needs = Keyword.get(opts, :needs, [])
    args = Keyword.get(opts, :args, [])

    # For now, only support local deployment
    if can_deploy_locally?(needs) do
      # Start the agent locally
      case agent_module.start_link(args) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_capable_nodes}
    end
  rescue
    e -> {:error, {:start_failed, e}}
  end

  @doc """
  Deploy to a specific node.

  Currently only supports the local node. Remote deployment will be added
  when mesh integration is complete.
  """
  @impl true
  def deploy_to_node(agent_module, node_id, opts \\ []) do
    if node_id == Node.self() do
      deploy(agent_module, opts)
    else
      {:error, :remote_deployment_not_implemented}
    end
  end

  # ==========================================================================
  # Capability Queries
  # ==========================================================================

  @doc """
  Find nodes with all specified capabilities.

  ## Options

  - `:min_load` - Minimum acceptable load score
  - `:max_load` - Maximum acceptable load score
  - `:limit` - Max nodes to return

  ## Examples

      {:ok, nodes} = Arbor.Cartographer.find_capable_nodes([:gpu, :high_memory])
      #=> [:"node1@host"]
  """
  @impl true
  def find_capable_nodes(capabilities, opts \\ []) do
    CapabilityRegistry.find_nodes(capabilities, opts)
  end

  @doc """
  Get capabilities of a specific node.
  """
  @impl true
  def get_node_capabilities(node_id) do
    CapabilityRegistry.get(node_id)
  end

  @doc """
  Get capabilities of all registered nodes.
  """
  @impl true
  def list_all_capabilities do
    CapabilityRegistry.list_all()
  end

  @doc """
  Get nodes that have a specific tag.
  """
  @impl true
  def nodes_with_tag(tag) do
    CapabilityRegistry.nodes_with_tag(tag)
  end

  @doc """
  Check if a node has specific capabilities.
  """
  @impl true
  def node_has_capabilities?(node_id, capabilities) do
    CapabilityRegistry.node_has_capabilities?(node_id, capabilities)
  end

  # ==========================================================================
  # Capability Registration
  # ==========================================================================

  @doc """
  Register additional capabilities for the current node.

  Hardware capabilities are auto-detected by the Scout. Use this to add
  custom tags like `:production` or `:gpu_optimized`.

  ## Examples

      :ok = Arbor.Cartographer.register_capabilities([:production, :gpu_optimized])
  """
  @impl true
  def register_capabilities(tags) when is_list(tags) do
    if Process.whereis(Scout) do
      Scout.add_custom_tags(tags)
    else
      {:error, :scout_not_running}
    end
  end

  @doc """
  Unregister capabilities from the current node.
  """
  @impl true
  def unregister_capabilities(tags) when is_list(tags) do
    if Process.whereis(Scout) do
      Scout.remove_custom_tags(tags)
    else
      :ok
    end
  end

  @doc """
  Get the current node's registered capabilities.
  """
  @impl true
  def my_capabilities do
    if Process.whereis(Scout) do
      Scout.capability_tags()
    else
      # Fallback to hardware detection if Scout isn't running
      {:ok, hardware} = Hardware.detect()
      {:ok, Hardware.to_capability_tags(hardware)}
    end
  end

  # ==========================================================================
  # Load Monitoring
  # ==========================================================================

  @doc """
  Get the current load score for a node.

  Load is a weighted combination of CPU and memory pressure (0-100).
  """
  @impl true
  def get_node_load(node_id) do
    CapabilityRegistry.get_load(node_id)
  end

  @doc """
  Get load scores for all nodes.
  """
  @impl true
  def get_all_loads do
    CapabilityRegistry.get_all_loads()
  end

  @doc """
  Update the load score for the current node.

  Called automatically by the Scout, but can be triggered manually.
  """
  @impl true
  def update_load do
    if Process.whereis(Scout) do
      # Scout handles load updates automatically
      :ok
    else
      :ok
    end
  end

  # ==========================================================================
  # Hardware Introspection
  # ==========================================================================

  @doc """
  Detect hardware capabilities of the current node.

  Returns detailed hardware info including:
  - Architecture (x86_64, arm64)
  - CPU count
  - Memory
  - GPUs
  - Accelerators (TPU, NCS)
  """
  @impl true
  def detect_hardware do
    if Process.whereis(Scout) do
      Scout.hardware_info()
    else
      Hardware.detect()
    end
  end

  @doc """
  Detect available LLM models on the current node.

  Checks for:
  - Ollama models
  - API keys (Claude, OpenAI, Gemini)
  - Local model files

  Note: Model detection is not yet implemented.
  """
  @impl true
  def detect_models do
    # TODO: Implement model detection
    # - Check for Ollama and list models
    # - Check for API keys in environment
    # - Check common model directories
    {:ok, detect_ollama_models() ++ detect_api_keys()}
  end

  # ==========================================================================
  # Affinity Management (Phase 2 - Planned)
  # ==========================================================================

  @doc """
  Set an affinity label for an agent.

  Note: Affinity management is planned for Phase 2.
  """
  @impl true
  def set_affinity(_agent_pid, _affinity_label) do
    :ok
  end

  @doc """
  Remove an affinity label from an agent.

  Note: Affinity management is planned for Phase 2.
  """
  @impl true
  def clear_affinity(_agent_pid) do
    :ok
  end

  @doc """
  Get all agents with a specific affinity label.

  Note: Affinity management is planned for Phase 2.
  """
  @impl true
  def agents_with_affinity(_affinity_label) do
    {:ok, []}
  end

  # ==========================================================================
  # Security Integration (Phase 3 - Future)
  # ==========================================================================

  @doc """
  Check if an agent can be deployed with given requirements.

  Note: Security integration is planned for Phase 3.
  """
  @impl true
  def authorize_deployment(_principal_id, capabilities) do
    # For now, just check if any node has the capabilities
    case find_capable_nodes(capabilities) do
      {:ok, [_ | _]} -> {:ok, :authorized}
      {:ok, []} -> {:error, :no_capable_nodes}
      error -> error
    end
  end

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  @doc """
  Start the Cartographer system.

  This is typically called automatically by the application supervisor.

  ## Options

  - `:introspection_interval` - How often to re-detect hardware (default: 5 min)
  - `:load_broadcast_interval` - How often to broadcast load (default: 30 sec)
  - `:custom_tags` - Additional capability tags to register
  """
  @impl true
  def start_link(opts \\ []) do
    # The supervisor is started by the application
    # This function is for manual starting if needed
    Arbor.Cartographer.Supervisor.start_link(opts)
  end

  @doc """
  Check if the Cartographer system is running and healthy.
  """
  @impl true
  def healthy? do
    supervisor_running?() && registry_running?() && scout_running?()
  end

  @doc """
  Get the Scout agent for this node.
  """
  @impl true
  def get_scout do
    case Process.whereis(Scout) do
      nil -> {:error, :not_running}
      pid -> {:ok, pid}
    end
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp can_deploy_locally?(needs) do
    case my_capabilities() do
      {:ok, tags} ->
        Enum.all?(needs, fn need -> need in tags end)

      {:error, _} ->
        false
    end
  end

  defp supervisor_running? do
    Process.whereis(Arbor.Cartographer.Supervisor) != nil
  end

  defp registry_running? do
    Process.whereis(CapabilityRegistry) != nil
  end

  defp scout_running? do
    Process.whereis(Scout) != nil
  end

  defp detect_ollama_models do
    case System.cmd("ollama", ["list"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        # Skip header
        |> Enum.drop(1)
        |> Enum.filter(&(String.trim(&1) != ""))
        |> Enum.map(fn line ->
          name =
            line
            |> String.split()
            |> List.first()
            |> String.split(":")
            |> List.first()

          {:ollama, String.to_atom(name)}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp detect_api_keys do
    api_checks = [
      {"ANTHROPIC_API_KEY", {:api, :claude}},
      {"OPENAI_API_KEY", {:api, :openai}},
      {"GOOGLE_API_KEY", {:api, :gemini}},
      {"GEMINI_API_KEY", {:api, :gemini}}
    ]

    Enum.flat_map(api_checks, fn {env_var, result} ->
      case System.get_env(env_var) do
        nil -> []
        "" -> []
        _ -> [result]
      end
    end)
    |> Enum.uniq()
  end
end
