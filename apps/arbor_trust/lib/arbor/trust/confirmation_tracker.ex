defmodule Arbor.Trust.ConfirmationTracker do
  @moduledoc """
  Tracks confirmation history for gated capabilities and manages
  graduation suggestions based on approval streaks.

  Part of the "confirm-then-automate" pattern: capabilities start as
  `:ask` (agent proposes action, user confirms), and after N successful
  confirmations without rejection, the system **suggests** upgrading to
  `:allow` or `:auto`. The user makes the final decision.

  ## Graduation Logic

  - Each (agent_id, uri_prefix) pair has a streak counter
  - Approvals increment the streak; rejections reset it to 0
  - When the streak reaches the graduation threshold, emits a
    `:graduation_suggested` signal instead of auto-promoting
  - The user can lock any URI prefix to suppress suggestions
  - Trust demotions reset all confirmation history via `reset/1`

  ## Default Thresholds

  | URI Prefix | Threshold | Rationale |
  |------------|-----------|-----------|
  | `arbor://code/read` | 0 | Already auto for most profiles |
  | `arbor://code/write` | 3 | Relatively low risk |
  | `arbor://network` | 5 | Moderate risk |
  | `arbor://ai` | 3 | Low risk |
  | `arbor://config` | 10 | High risk, needs more evidence |
  | `arbor://shell` | `:never` | Security invariant: never auto |
  | `arbor://governance` | `:never` | Always human-confirmed |

  ## Configuration

      config :arbor_trust, :graduation_thresholds, %{
        "arbor://shell" => :never,
        "arbor://governance" => :never,
        "arbor://code/write" => 5
      }

  ## Storage

  State is stored in ETS for O(1) lookups during authorization.
  Currently does not persist across restarts (fail-safe: fresh start
  is more conservative). Persistence can be added via BufferedStore
  when needed.
  """

  use GenServer

  require Logger

  @table :arbor_confirmation_tracker

  @default_thresholds %{
    "arbor://code/read" => 0,
    "arbor://code/write" => 3,
    "arbor://shell" => :never,
    "arbor://network" => 5,
    "arbor://ai" => 3,
    "arbor://config" => 10,
    "arbor://governance" => :never
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
  threshold, emits a `:graduation_suggested` signal and returns
  `{:graduation_suggested, uri_prefix}`.
  """
  @spec record_approval(String.t(), String.t()) :: :ok | {:graduation_suggested, String.t()}
  def record_approval(agent_id, resource_uri) do
    GenServer.call(__MODULE__, {:record_approval, agent_id, resource_uri})
  end

  @doc """
  Record a rejection for an agent's capability use.

  Resets the streak counter to 0.
  """
  @spec record_rejection(String.t(), String.t()) :: :ok
  def record_rejection(agent_id, resource_uri) do
    GenServer.call(__MODULE__, {:record_rejection, agent_id, resource_uri})
  end

  @doc """
  Check if a capability has graduated to auto-approve for an agent.

  Uses longest-prefix match against tracked entries in ETS.
  This is the fast path — reads directly from ETS without going
  through the GenServer, so it's safe to call from the authorization
  pipeline.
  """
  @spec graduated?(String.t(), String.t()) :: boolean()
  def graduated?(agent_id, resource_uri) do
    uri_prefix = resolve_tracking_prefix(resource_uri)

    if uri_prefix do
      graduated_prefix?(agent_id, uri_prefix)
    else
      false
    end
  end

  @doc """
  Check if a specific URI prefix has graduated for an agent.
  """
  @spec graduated_prefix?(String.t(), String.t()) :: boolean()
  def graduated_prefix?(agent_id, uri_prefix) when is_binary(uri_prefix) do
    case :ets.lookup(@table, {agent_id, uri_prefix}) do
      [{_, entry}] -> entry.graduated and not entry.locked
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Revert a graduated URI prefix back to gated.
  """
  @spec revert_to_gated(String.t(), String.t()) :: :ok
  def revert_to_gated(agent_id, uri_prefix) when is_binary(uri_prefix) do
    GenServer.call(__MODULE__, {:revert_to_gated, agent_id, uri_prefix})
  end

  @doc """
  Lock a URI prefix as permanently gated for an agent (user preference).

  Locked prefixes never trigger graduation suggestions.
  """
  @spec lock_gated(String.t(), String.t()) :: :ok
  def lock_gated(agent_id, uri_prefix) when is_binary(uri_prefix) do
    GenServer.call(__MODULE__, {:lock_gated, agent_id, uri_prefix})
  end

  @doc """
  Unlock a previously locked URI prefix.
  """
  @spec unlock_gated(String.t(), String.t()) :: :ok
  def unlock_gated(agent_id, uri_prefix) when is_binary(uri_prefix) do
    GenServer.call(__MODULE__, {:unlock_gated, agent_id, uri_prefix})
  end

  @doc """
  Get the current confirmation status for an agent's URI prefix.
  """
  @spec status(String.t(), String.t()) :: map()
  def status(agent_id, uri_prefix) when is_binary(uri_prefix) do
    case :ets.lookup(@table, {agent_id, uri_prefix}) do
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
  Get the graduation threshold for a URI prefix.

  Uses longest-prefix match against configured thresholds.
  Returns the number of consecutive approvals needed to graduate,
  or `:never` if the prefix can never be auto-approved.
  """
  @spec threshold_for(String.t()) :: non_neg_integer() | :never
  def threshold_for(uri_prefix) when is_binary(uri_prefix) do
    thresholds = configured_thresholds()
    resolve_threshold(thresholds, uri_prefix)
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
    uri_prefix = resolve_tracking_prefix(resource_uri)

    if is_nil(uri_prefix) do
      {:reply, :ok, state}
    else
      entry = get_or_create(agent_id, uri_prefix)
      threshold = threshold_for(uri_prefix)

      updated =
        %{entry |
          approvals: entry.approvals + 1,
          streak: entry.streak + 1,
          last_confirmation: DateTime.utc_now()
        }

      # Check graduation
      {updated, just_graduated} =
        if should_graduate?(updated, threshold) do
          Logger.info(
            "[ConfirmationTracker] URI prefix #{uri_prefix} reached graduation threshold " <>
            "for agent #{agent_id} (streak: #{updated.streak}, threshold: #{threshold})",
            agent_id: agent_id,
            uri_prefix: uri_prefix
          )
          {%{updated | graduated: true, graduated_at: DateTime.utc_now()}, not entry.graduated}
        else
          {updated, false}
        end

      :ets.insert(@table, {{agent_id, uri_prefix}, updated})

      reply =
        if just_graduated do
          # Emit graduation suggestion signal
          safe_emit(:graduation_suggested, %{
            agent_id: agent_id,
            uri_prefix: uri_prefix,
            current_mode: :ask,
            suggested_mode: :allow,
            streak: updated.streak,
            threshold: threshold
          })

          {:graduation_suggested, uri_prefix}
        else
          :ok
        end

      safe_emit(:confirmation_recorded, %{
        agent_id: agent_id,
        uri_prefix: uri_prefix,
        action: :approval,
        streak: updated.streak,
        graduated: updated.graduated
      })

      {:reply, reply, state}
    end
  end

  def handle_call({:record_rejection, agent_id, resource_uri}, _from, state) do
    uri_prefix = resolve_tracking_prefix(resource_uri)

    if is_nil(uri_prefix) do
      {:reply, :ok, state}
    else
      entry = get_or_create(agent_id, uri_prefix)
      was_graduated = entry.graduated

      updated =
        %{entry |
          rejections: entry.rejections + 1,
          streak: 0,
          graduated: false,
          graduated_at: nil,
          last_confirmation: DateTime.utc_now()
        }

      :ets.insert(@table, {{agent_id, uri_prefix}, updated})

      if was_graduated do
        Logger.info(
          "[ConfirmationTracker] URI prefix #{uri_prefix} reverted from graduated " <>
          "for agent #{agent_id} (rejection)",
          agent_id: agent_id,
          uri_prefix: uri_prefix
        )
      end

      safe_emit(:confirmation_recorded, %{
        agent_id: agent_id,
        uri_prefix: uri_prefix,
        action: :rejection,
        streak: 0,
        was_graduated: was_graduated
      })

      {:reply, :ok, state}
    end
  end

  def handle_call({:revert_to_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = %{entry | graduated: false, graduated_at: nil, streak: 0}
    :ets.insert(@table, {{agent_id, uri_prefix}, updated})

    safe_emit(:graduation_reverted, %{agent_id: agent_id, uri_prefix: uri_prefix})

    {:reply, :ok, state}
  end

  def handle_call({:lock_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = %{entry | locked: true, graduated: false, graduated_at: nil}
    :ets.insert(@table, {{agent_id, uri_prefix}, updated})

    safe_emit(:prefix_locked, %{agent_id: agent_id, uri_prefix: uri_prefix})

    {:reply, :ok, state}
  end

  def handle_call({:unlock_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = %{entry | locked: false}
    :ets.insert(@table, {{agent_id, uri_prefix}, updated})

    safe_emit(:prefix_unlocked, %{agent_id: agent_id, uri_prefix: uri_prefix})

    {:reply, :ok, state}
  end

  def handle_call({:reset, agent_id}, _from, state) do
    # Delete all entries for this agent
    :ets.match_delete(@table, {{agent_id, :_}, :_})

    safe_emit(:confirmation_reset, %{agent_id: agent_id})

    {:reply, :ok, state}
  end

  # =========================================================================
  # URI Prefix Resolution
  # =========================================================================

  @doc """
  Resolve a resource URI to the tracking prefix used for confirmation tracking.

  Uses longest-prefix match against the configured threshold prefixes.
  Returns nil if no threshold prefix matches the URI.
  """
  @spec resolve_tracking_prefix(String.t()) :: String.t() | nil
  def resolve_tracking_prefix(resource_uri) when is_binary(resource_uri) do
    thresholds = configured_thresholds()

    thresholds
    |> Map.keys()
    |> Enum.filter(fn prefix -> String.starts_with?(resource_uri, prefix) end)
    |> case do
      [] -> nil
      matches -> Enum.max_by(matches, &byte_size/1)
    end
  end

  # =========================================================================
  # Internals
  # =========================================================================

  defp get_or_create(agent_id, uri_prefix) do
    case :ets.lookup(@table, {agent_id, uri_prefix}) do
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

  defp resolve_threshold(thresholds, uri_prefix) do
    # Longest-prefix match against threshold keys
    thresholds
    |> Enum.filter(fn {prefix, _} -> String.starts_with?(uri_prefix, prefix) end)
    |> case do
      [] -> 5
      matches -> matches |> Enum.max_by(fn {prefix, _} -> byte_size(prefix) end) |> elem(1)
    end
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
