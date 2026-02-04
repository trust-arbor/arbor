defmodule Arbor.Sandbox do
  @moduledoc """
  Unified sandboxing for Arbor agents and code execution.

  Arbor.Sandbox provides multiple layers of sandboxing for safe execution:

  ## Sandbox Types

  | Type | Purpose |
  |------|---------|
  | `Filesystem` | Per-agent isolated directories |
  | `Code` | AST-level validation and module allowlists |
  | `Virtual` | In-memory VFS via jido_sandbox |

  ## Sandbox Levels

  | Level | Filesystem | Code |
  |-------|------------|------|
  | `:pure` | Read-only | Kernel only |
  | `:limited` | Scoped write | Whitelisted modules |
  | `:full` | Full access | All (except dangerous) |
  | `:container` | Docker isolation | N/A |

  ## Usage

      # Create a sandbox for an agent
      {:ok, sandbox} = Arbor.Sandbox.create("agent_001", level: :limited)

      # Check if an operation is allowed
      :ok = Arbor.Sandbox.check_path(sandbox, "/project/src/file.ex", :read)

      # Check if code is safe to execute
      :ok = Arbor.Sandbox.check_code(sandbox, code_ast)

      # Use virtual filesystem for preview
      {:ok, vfs} = Arbor.Sandbox.create_virtual()
      {:ok, vfs} = Arbor.Sandbox.vfs_write(vfs, "/test.ex", "IO.puts(:hello)")

  ## Integration with Trust

  Sandbox levels can be derived from trust tiers:

      {:ok, level} = Arbor.Sandbox.level_for_trust(:probationary)
      # => :limited
  """

  alias Arbor.Contracts.Security.TrustBounds
  alias Arbor.Sandbox.{Code, Filesystem, Registry, Virtual}
  alias Arbor.Signals

  @type sandbox_id :: String.t()
  @type level :: :pure | :limited | :full | :container

  @trust_to_level %{
    untrusted: :pure,
    probationary: :limited,
    trusted: :limited,
    veteran: :full,
    autonomous: :full
  }

  # ── Authorized API (for agent callers) ──

  @doc """
  Create a sandbox with authorization check.

  Verifies the agent has the `arbor://sandbox/create` capability before
  creating a sandbox. Use this for agent-initiated sandbox creation where
  authorization should be enforced.

  ## Parameters

  - `caller_id` - The calling agent's ID for capability lookup
  - `target_agent_id` - The agent ID the sandbox is being created for
  - `opts` - Options passed to `create/2`, plus optional `:trace_id` for correlation

  ## Returns

  - `{:ok, sandbox}` on success
  - `{:error, {:unauthorized, reason}}` if caller lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_create(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_create(caller_id, target_agent_id, opts \\ []) do
    resource = "arbor://sandbox/create"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(caller_id, resource, :create, trace_id: trace_id) do
      {:ok, :authorized} ->
        create(target_agent_id, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Destroy a sandbox with authorization check.

  Verifies the agent has the `arbor://sandbox/destroy` capability before
  destroying the sandbox. Use this for agent-initiated sandbox destruction
  where authorization should be enforced.

  ## Parameters

  - `caller_id` - The calling agent's ID for capability lookup
  - `sandbox_id` - The ID of the sandbox to destroy
  - `opts` - Additional options, including optional `:trace_id` for correlation

  ## Returns

  - `:ok` on success
  - `{:error, {:unauthorized, reason}}` if caller lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_destroy(String.t(), sandbox_id(), keyword()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_destroy(caller_id, sandbox_id, opts \\ []) do
    resource = "arbor://sandbox/destroy"
    {trace_id, _opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(caller_id, resource, :destroy, trace_id: trace_id) do
      {:ok, :authorized} ->
        destroy(sandbox_id)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  # Sandbox Lifecycle

  @doc """
  Create a new sandbox for an agent.

  ## Options

  - `:level` - Sandbox level (default: `:limited`)
  - `:base_path` - Base path for filesystem sandbox
  - `:trust_tier` - Derive level from trust tier
  """
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(agent_id, opts \\ []) do
    level = determine_level(opts)

    sandbox = %{
      id: generate_sandbox_id(),
      agent_id: agent_id,
      level: level,
      created_at: DateTime.utc_now(),
      filesystem: nil,
      virtual: nil
    }

    # Initialize filesystem sandbox
    sandbox =
      case Filesystem.create(agent_id, level, opts) do
        {:ok, fs} -> %{sandbox | filesystem: fs}
        {:error, _} -> sandbox
      end

    :ok = Registry.register(sandbox)
    emit_sandbox_created(sandbox)

    {:ok, sandbox}
  end

  @doc """
  Get an existing sandbox by ID or agent ID.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id_or_agent_id) do
    Registry.get(id_or_agent_id)
  end

  @doc """
  Destroy a sandbox and clean up resources.
  """
  @spec destroy(sandbox_id()) :: :ok | {:error, term()}
  def destroy(sandbox_id) do
    case Registry.get(sandbox_id) do
      {:ok, sandbox} ->
        Filesystem.cleanup(sandbox.filesystem)
        Registry.unregister(sandbox_id)
        emit_sandbox_destroyed(sandbox)
        :ok

      error ->
        error
    end
  end

  # Filesystem Operations

  @doc """
  Check if a path operation is allowed.
  """
  @spec check_path(map(), String.t(), :read | :write | :delete) :: :ok | {:error, term()}
  def check_path(%{filesystem: fs, level: level}, path, operation) do
    Filesystem.check(fs, path, operation, level)
  end

  @doc """
  Get the sandboxed path for an agent.
  """
  @spec sandboxed_path(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sandboxed_path(%{filesystem: fs}, relative_path) do
    Filesystem.resolve_path(fs, relative_path)
  end

  # Code Validation

  @doc """
  Check if code is safe to execute at the given sandbox level.
  """
  @spec check_code(map(), Macro.t()) :: :ok | {:error, term()}
  def check_code(%{level: level}, ast) do
    Code.validate(ast, level)
  end

  @doc """
  Check if a module is allowed at the given sandbox level.
  """
  @spec check_module(map(), module()) :: :ok | {:error, :module_not_allowed}
  def check_module(%{level: level}, module) do
    Code.check_module(module, level)
  end

  # Virtual Filesystem

  @doc """
  Create a virtual filesystem for preview/dry-run.
  """
  @spec create_virtual(keyword()) :: {:ok, map()}
  def create_virtual(opts \\ []) do
    Virtual.create(opts)
  end

  @doc """
  Write to the virtual filesystem.
  """
  @spec vfs_write(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def vfs_write(vfs, path, content) do
    Virtual.write(vfs, path, content)
  end

  @doc """
  Read from the virtual filesystem.
  """
  @spec vfs_read(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def vfs_read(vfs, path) do
    Virtual.read(vfs, path)
  end

  @doc """
  Create a snapshot of the virtual filesystem.
  """
  @spec vfs_snapshot(map()) :: {:ok, String.t(), map()}
  def vfs_snapshot(vfs) do
    Virtual.snapshot(vfs)
  end

  @doc """
  Restore a virtual filesystem from a snapshot.
  """
  @spec vfs_restore(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def vfs_restore(vfs, snapshot_id) do
    Virtual.restore(vfs, snapshot_id)
  end

  # Trust Integration

  @doc """
  Get the sandbox level for a trust tier.
  """
  @spec level_for_trust(atom()) :: {:ok, level()} | {:error, :unknown_tier}
  def level_for_trust(tier) when is_map_key(@trust_to_level, tier) do
    {:ok, Map.fetch!(@trust_to_level, tier)}
  end

  def level_for_trust(_tier), do: {:error, :unknown_tier}

  @doc """
  Get full sandbox configuration for a trust tier.

  Returns a map with sandbox settings derived from the trust tier,
  using TrustBounds for the tier-to-level mapping.

  ## Example

      config = Arbor.Sandbox.config_for_tier(:trusted)
      # => %{
      #      level: :standard,
      #      allowed_modules: [...],
      #      restricted_functions: [...],
      #      file_access: :scoped,
      #      network_access: :allowed
      #    }
  """
  @spec config_for_tier(atom()) :: map()
  def config_for_tier(tier) do
    level = TrustBounds.sandbox_for_tier(tier)

    %{
      level: level,
      allowed_modules: Code.allowed_modules(level),
      restricted_functions: Code.restricted_functions(level),
      file_access: file_access_for(level),
      network_access: network_access_for(level),
      trust_tier: tier
    }
  end

  # File access rules by sandbox level
  # Maps TrustBounds sandbox levels to file access policies
  defp file_access_for(:strict), do: :read_only
  defp file_access_for(:standard), do: :scoped
  defp file_access_for(:permissive), do: :full
  defp file_access_for(:none), do: :full

  # Network access rules by sandbox level
  # Maps TrustBounds sandbox levels to network access policies
  defp network_access_for(:strict), do: :denied
  defp network_access_for(:standard), do: :allowed
  defp network_access_for(:permissive), do: :allowed
  defp network_access_for(:none), do: :allowed

  # System API

  @doc """
  List all active sandboxes.
  """
  @spec list(keyword()) :: {:ok, [map()]}
  def list(opts \\ []) do
    Registry.list(opts)
  end

  @doc """
  Check if sandbox system is healthy.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(Registry) != nil
  end

  # Private functions

  defp determine_level(opts) do
    cond do
      Keyword.has_key?(opts, :level) ->
        Keyword.fetch!(opts, :level)

      Keyword.has_key?(opts, :trust_tier) ->
        tier = Keyword.fetch!(opts, :trust_tier)
        Map.get(@trust_to_level, tier, :limited)

      true ->
        :limited
    end
  end

  defp generate_sandbox_id do
    "sbx_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_sandbox_created(sandbox) do
    Signals.emit(:sandbox, :created, %{
      sandbox_id: sandbox.id,
      agent_id: sandbox.agent_id,
      level: sandbox.level
    })
  end

  defp emit_sandbox_destroyed(sandbox) do
    Signals.emit(:sandbox, :destroyed, %{
      sandbox_id: sandbox.id,
      agent_id: sandbox.agent_id
    })
  end
end
