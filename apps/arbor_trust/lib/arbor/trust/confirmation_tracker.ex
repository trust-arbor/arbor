defmodule Arbor.Trust.ConfirmationTracker do
  @moduledoc """
  Tracks confirmation history for gated capabilities and manages
  graduation from gated to auto-approve.

  Part of the "confirm-then-automate" pattern: capabilities start as
  `gated` (agent proposes action, user confirms), and after N successful
  confirmations without rejection, the capability graduates to `auto`.

  ## Graduation Logic

  - Each (agent_id, bundle) pair has a streak counter
  - Approvals increment the streak; rejections reset it to 0
  - When the streak reaches the graduation threshold, `graduated?/2` returns true
  - The user can revert any graduation via `revert_to_gated/2`
  - Bundles can be locked as permanently gated via `lock_gated/2`
  - Trust demotions reset all confirmation history via `reset/1`

  ## Default Thresholds

  | Bundle | Threshold | Rationale |
  |--------|-----------|-----------|
  | `codebase_read` | 0 | Already auto in confirmation matrix |
  | `codebase_write` | 3 | Relatively low risk |
  | `network` | 5 | Moderate risk |
  | `ai_generate` | 3 | Low risk |
  | `system_config` | 10 | High risk, needs more evidence |
  | `shell` | `:never` | Security invariant: never auto |
  | `governance` | `:never` | Always human-confirmed |

  ## Configuration

      config :arbor_trust, :graduation_thresholds, %{
        shell: :never,
        governance: :never,
        codebase_write: 5
      }

  ## Storage

  State is stored in ETS for O(1) lookups during authorization.
  Currently does not persist across restarts (fail-safe: fresh start
  is more conservative). Persistence can be added via BufferedStore
  when needed.
  """

  use GenServer

  alias Arbor.Trust.ConfirmationMatrix

  require Logger

  @table :arbor_confirmation_tracker

  @default_thresholds %{
    codebase_read: 0,
    codebase_write: 3,
    shell: :never,
    network: 5,
    ai_generate: 3,
    system_config: 10,
    governance: :never
  }

  # =========================================================================
  # Public API
  # =========================================================================

  @doc """
  Start the ConfirmationTracker.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a successful approval for an agent's capability use.

  Increments the streak counter. If the streak reaches the graduation
  threshold, returns `{:graduated, bundle}` to signal the agent that
  this capability can now be auto-approved.
  """
  @spec record_approval(String.t(), String.t()) :: :ok | {:graduated, atom()}
  def record_approval(agent_id, resource_uri) do
    GenServer.call(__MODULE__, {:record_approval, agent_id, resource_uri})
  end

  @doc """
  Record a rejection for an agent's capability use.

  Resets the streak counter to 0 and reverts any graduation.
  """
  @spec record_rejection(String.t(), String.t()) :: :ok
  def record_rejection(agent_id, resource_uri) do
    GenServer.call(__MODULE__, {:record_rejection, agent_id, resource_uri})
  end

  @doc """
  Check if a capability has graduated to auto-approve for an agent.

  This is the fast path — reads directly from ETS without going
  through the GenServer, so it's safe to call from the authorization
  pipeline.
  """
  @spec graduated?(String.t(), String.t()) :: boolean()
  def graduated?(agent_id, resource_uri) do
    bundle = ConfirmationMatrix.resolve_bundle(resource_uri)
    graduated_bundle?(agent_id, bundle)
  end

  @doc """
  Check if a specific bundle has graduated for an agent.
  """
  @spec graduated_bundle?(String.t(), atom() | nil) :: boolean()
  def graduated_bundle?(_agent_id, nil), do: false

  def graduated_bundle?(agent_id, bundle) do
    case :ets.lookup(@table, {agent_id, bundle}) do
      [{_, entry}] -> entry.graduated and not entry.locked
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Revert a graduated capability back to gated.
  """
  @spec revert_to_gated(String.t(), atom()) :: :ok
  def revert_to_gated(agent_id, bundle) do
    GenServer.call(__MODULE__, {:revert_to_gated, agent_id, bundle})
  end

  @doc """
  Lock a bundle as permanently gated for an agent (user preference).
  """
  @spec lock_gated(String.t(), atom()) :: :ok
  def lock_gated(agent_id, bundle) do
    GenServer.call(__MODULE__, {:lock_gated, agent_id, bundle})
  end

  @doc """
  Unlock a previously locked bundle.
  """
  @spec unlock_gated(String.t(), atom()) :: :ok
  def unlock_gated(agent_id, bundle) do
    GenServer.call(__MODULE__, {:unlock_gated, agent_id, bundle})
  end

  @doc """
  Get the current confirmation status for an agent's bundle.
  """
  @spec status(String.t(), atom()) :: map()
  def status(agent_id, bundle) do
    case :ets.lookup(@table, {agent_id, bundle}) do
      [{_, entry}] -> entry
      [] -> new_entry()
    end
  rescue
    ArgumentError -> new_entry()
  end

  @doc """
  Reset all confirmation history for an agent (used on trust demotion).
  """
  @spec reset(String.t()) :: :ok
  def reset(agent_id) do
    GenServer.call(__MODULE__, {:reset, agent_id})
  end

  @doc """
  Get the graduation threshold for a bundle.

  Returns the number of consecutive approvals needed to graduate,
  or `:never` if the bundle can never be auto-approved.
  """
  @spec threshold_for(atom()) :: non_neg_integer() | :never
  def threshold_for(bundle) do
    thresholds = configured_thresholds()
    Map.get(thresholds, bundle, 5)
  end

  # =========================================================================
  # GenServer callbacks
  # =========================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record_approval, agent_id, resource_uri}, _from, state) do
    bundle = ConfirmationMatrix.resolve_bundle(resource_uri)

    if is_nil(bundle) do
      {:reply, :ok, state}
    else
      entry = get_or_create(agent_id, bundle)
      threshold = threshold_for(bundle)

      updated =
        %{entry |
          approvals: entry.approvals + 1,
          streak: entry.streak + 1,
          last_confirmation: DateTime.utc_now()
        }

      # Check graduation
      updated =
        if should_graduate?(updated, threshold) do
          Logger.info(
            "[ConfirmationTracker] Bundle #{bundle} graduated for agent #{agent_id} " <>
            "(streak: #{updated.streak}, threshold: #{threshold})",
            agent_id: agent_id,
            bundle: bundle
          )
          %{updated | graduated: true, graduated_at: DateTime.utc_now()}
        else
          updated
        end

      :ets.insert(@table, {{agent_id, bundle}, updated})

      reply =
        if updated.graduated and not entry.graduated do
          {:graduated, bundle}
        else
          :ok
        end

      safe_emit(:confirmation_recorded, %{
        agent_id: agent_id,
        bundle: bundle,
        action: :approval,
        streak: updated.streak,
        graduated: updated.graduated
      })

      {:reply, reply, state}
    end
  end

  def handle_call({:record_rejection, agent_id, resource_uri}, _from, state) do
    bundle = ConfirmationMatrix.resolve_bundle(resource_uri)

    if is_nil(bundle) do
      {:reply, :ok, state}
    else
      entry = get_or_create(agent_id, bundle)
      was_graduated = entry.graduated

      updated =
        %{entry |
          rejections: entry.rejections + 1,
          streak: 0,
          graduated: false,
          graduated_at: nil,
          last_confirmation: DateTime.utc_now()
        }

      :ets.insert(@table, {{agent_id, bundle}, updated})

      if was_graduated do
        Logger.info(
          "[ConfirmationTracker] Bundle #{bundle} reverted from graduated for agent #{agent_id} (rejection)",
          agent_id: agent_id,
          bundle: bundle
        )
      end

      safe_emit(:confirmation_recorded, %{
        agent_id: agent_id,
        bundle: bundle,
        action: :rejection,
        streak: 0,
        was_graduated: was_graduated
      })

      {:reply, :ok, state}
    end
  end

  def handle_call({:revert_to_gated, agent_id, bundle}, _from, state) do
    entry = get_or_create(agent_id, bundle)
    updated = %{entry | graduated: false, graduated_at: nil, streak: 0}
    :ets.insert(@table, {{agent_id, bundle}, updated})

    safe_emit(:graduation_reverted, %{agent_id: agent_id, bundle: bundle})

    {:reply, :ok, state}
  end

  def handle_call({:lock_gated, agent_id, bundle}, _from, state) do
    entry = get_or_create(agent_id, bundle)
    updated = %{entry | locked: true, graduated: false, graduated_at: nil}
    :ets.insert(@table, {{agent_id, bundle}, updated})

    safe_emit(:bundle_locked, %{agent_id: agent_id, bundle: bundle})

    {:reply, :ok, state}
  end

  def handle_call({:unlock_gated, agent_id, bundle}, _from, state) do
    entry = get_or_create(agent_id, bundle)
    updated = %{entry | locked: false}
    :ets.insert(@table, {{agent_id, bundle}, updated})

    safe_emit(:bundle_unlocked, %{agent_id: agent_id, bundle: bundle})

    {:reply, :ok, state}
  end

  def handle_call({:reset, agent_id}, _from, state) do
    # Delete all entries for this agent
    :ets.match_delete(@table, {{agent_id, :_}, :_})

    safe_emit(:confirmation_reset, %{agent_id: agent_id})

    {:reply, :ok, state}
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp get_or_create(agent_id, bundle) do
    case :ets.lookup(@table, {agent_id, bundle}) do
      [{_, entry}] -> entry
      [] -> new_entry()
    end
  end

  defp new_entry do
    %{
      approvals: 0,
      rejections: 0,
      streak: 0,
      graduated: false,
      locked: false,
      last_confirmation: nil,
      graduated_at: nil
    }
  end

  defp should_graduate?(entry, threshold) do
    cond do
      threshold == :never -> false
      threshold == 0 -> true
      entry.locked -> false
      entry.graduated -> false
      entry.streak >= threshold -> true
      true -> false
    end
  end

  defp configured_thresholds do
    config = Application.get_env(:arbor_trust, :graduation_thresholds, %{})
    Map.merge(@default_thresholds, config)
  end

  defp safe_emit(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      Arbor.Signals.emit(:trust, type, data)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
