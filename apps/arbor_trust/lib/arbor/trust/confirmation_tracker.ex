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
  - Only source-verified human approvals increment the qualifying streak;
    rejection or an unknown responder resets that streak
  - A current eligible profile and human streak produce an exact, revision-bound
    `:graduation_suggested` signal; no authority changes automatically
  - The user can lock any URI prefix to suppress suggestions
  - Trust demotions reset all confirmation history via `reset/1`

  ## Default Thresholds

  Default thresholds are projected from `CapabilityProfile` metadata via
  `Arbor.Trust.CapabilityRiskProfiles.graduation_thresholds/0`. High-risk local
  writes need three successful approvals, network egress and process-spawn
  profiles need five, and critical / irreversible / governance / trust /
  identity / financial profiles never graduate.

  ## Configuration

      config :arbor_trust, :graduation_thresholds, %{
        "arbor://shell" => :never,
        "arbor://governance" => :never,
        "arbor://code/write" => 5
      }

  ## Storage & persistence (TRUST-6, 2026-06-14)

  Request-keyed observations use the same owner as these counters. Their
  bounded replay set is retained across per-agent resets; restarting the
  tracker loses counters and replay state together. This is an advisory
  process lifetime, not a durable approval audit.

  The source-revalidated answer API admits human evidence only when the
  winning owner verified that responder's live session proof and current
  approval authority. Legacy and recovered answers remain unknown; caller
  metadata cannot upgrade them. Legacy two-argument
  counter APIs remain advisory compatibility surfaces, not verified evidence.
  Even an accepted profile rule cannot relax the current default write
  ceilings, which continue to require approval.

  This tracker holds only the **transient** streak counters in ETS — the
  bookkeeping *toward* a suggestion. It does NOT persist across restarts, and
  that is correct: re-accumulating a streak after a reboot is harmless.

  The **earned result** does not live here. When a human accepts a graduation
  suggestion (`Arbor.Trust.accept_graduation/3`), it is recorded as a profile
  rule (`rules[prefix] => :auto`) on the agent's trust profile, which already
  persists. So earned autonomy survives restarts via the profile — there is no
  separate persistence mechanism here to protect.

  Critically, this tracker is **advisory only**: nothing in the authorization
  path reads its `graduated?` flag. Authorization reads the profile
  (`Policy.effective_mode/3`), where the security ceiling still caps the result
  (graduating an always-locked/egress URI cannot bypass its ceiling).
  """

  use GenServer

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Trust.ApprovalEvidenceCore
  alias Arbor.Trust.CapabilityRiskProfiles
  alias Arbor.Trust.Config
  alias Arbor.Trust.{GraduationCore, PolicyHost, Store}

  @table :arbor_confirmation_tracker
  @fallback_threshold 5

  # =========================================================================
  # Public API
  # =========================================================================

  @doc """
  Start the ConfirmationTracker.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def record_approval_answer(source, request_id, expected) do
    GenServer.call(__MODULE__, {:record_approval_answer, source, request_id, expected})
  end

  @doc false
  def list_graduations(agent_id, opts), do: call_graduation({:list_graduations, agent_id, opts})

  @doc false
  def graduation_status(agent_id, prefix, opts),
    do: call_graduation({:graduation_status, agent_id, prefix, opts})

  @doc false
  def decide_graduation(agent_id, prefix, operation, opts),
    do: call_graduation({:decide_graduation, agent_id, prefix, operation, opts})

  defp call_graduation(message) do
    GenServer.call(__MODULE__, message, 10_000)
  catch
    :exit, _ -> graduation_call_exit(message)
  end

  defp graduation_call_exit({:decide_graduation, _, _, :accept, _}),
    do: {:error, :graduation_store_outcome_unknown}

  defp graduation_call_exit(_message), do: {:error, :graduation_unavailable}

  @impl true
  def format_status(status) when is_map(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  @doc """
  Record a successful approval for an agent's capability use.

  Advisory compatibility API. No verified responder or winning request is
  supplied, so this never creates a graduation suggestion.
  """
  @spec record_approval(String.t(), String.t()) :: :ok
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
    {:ok, %{table: table, answers: ApprovalEvidenceCore.new()}}
  end

  @impl true
  def handle_call({:record_approval_answer, source, request_id, expected}, _from, state) do
    with {:ok, expected} <- ApprovalEvidenceCore.validate_expected(source, request_id, expected),
         {:ok, record} <- read_answered_approval(source, request_id),
         :ok <- ApprovalEvidenceCore.validate_record(expected, record),
         {:ok, disposition, answers} <- ApprovalEvidenceCore.admit(state.answers, record) do
      if disposition == :recorded, do: record_answer_evidence(record)
      {:reply, {:ok, disposition}, %{state | answers: answers}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_approval, agent_id, resource_uri}, _from, state) do
    record_answer_evidence(%{
      agent_id: agent_id,
      resource_uri: resource_uri,
      decision: :approve,
      source: :legacy,
      request_id: nil
    })

    {:reply, :ok, state}
  end

  def handle_call({:record_rejection, agent_id, resource_uri}, _from, state) do
    record_answer_evidence(%{
      agent_id: agent_id,
      resource_uri: resource_uri,
      decision: :deny,
      source: :legacy,
      request_id: nil
    })

    {:reply, :ok, state}
  end

  def handle_call({:list_graduations, agent_id, opts}, _from, state) do
    case authorize_graduation(agent_id, :read, opts) do
      {:ok, _proof} ->
        rows = :ets.match_object(@table, {{agent_id, :_}, :_})

        statuses =
          Enum.map(rows, fn {{_, prefix}, entry} -> show_graduation(agent_id, prefix, entry) end)

        {:reply, {:ok, Enum.sort_by(statuses, & &1.uri_prefix)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:graduation_status, agent_id, prefix, opts}, _from, state) do
    with true <- GraduationCore.valid_prefix?(prefix),
         {:ok, _proof} <- authorize_graduation(agent_id, :read, opts) do
      {:reply, {:ok, show_graduation(agent_id, prefix, get_or_create(agent_id, prefix))}, state}
    else
      false -> {:reply, {:error, :invalid_graduation_prefix}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:decide_graduation, agent_id, prefix, operation, opts}, _from, state) do
    entry = get_or_create(agent_id, prefix)

    with true <- GraduationCore.valid_prefix?(prefix),
         {:ok, proof} <- authorize_graduation(agent_id, operation, opts),
         {profile, eligibility} <- graduation_inputs(agent_id, prefix, entry),
         {:ok, updated, effects} <-
           GraduationCore.decide(entry, proof.suggestion_id, eligibility, profile, operation),
         :ok <- perform_graduation_effects(effects, agent_id, prefix, entry, profile, proof) do
      :ets.insert(@table, {{agent_id, prefix}, updated})

      safe_emit(:graduation_decided, %{
        agent_id: agent_id,
        uri_prefix: prefix,
        suggestion_id: proof.suggestion_id,
        decision: operation,
        actor_id: proof.caller_id
      })

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :invalid_graduation_prefix}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:revert_to_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = entry |> GraduationCore.invalidate() |> Map.merge(%{streak: 0, human_streak: 0})
    :ets.insert(@table, {{agent_id, uri_prefix}, updated})

    safe_emit(:graduation_reverted, %{agent_id: agent_id, uri_prefix: uri_prefix})

    {:reply, :ok, state}
  end

  def handle_call({:lock_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = entry |> GraduationCore.invalidate() |> Map.put(:locked, true)
    :ets.insert(@table, {{agent_id, uri_prefix}, updated})

    safe_emit(:prefix_locked, %{agent_id: agent_id, uri_prefix: uri_prefix})

    {:reply, :ok, state}
  end

  def handle_call({:unlock_gated, agent_id, uri_prefix}, _from, state) do
    entry = get_or_create(agent_id, uri_prefix)
    updated = entry |> GraduationCore.invalidate() |> Map.put(:locked, false)
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
    |> Enum.filter(&CapabilityUri.prefix_match?(&1, resource_uri))
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
      graduated_at: nil,
      unknown_approvals: 0,
      unknown_rejections: 0,
      verified_human_approvals: 0,
      human_streak: 0,
      revision: 0,
      suggestion_id: nil,
      suggestion_profile_updated_at: nil
    }
  end

  defp read_answered_approval(source, request_id) do
    provider = Config.approval_evidence_provider()

    if is_atom(provider) and not is_nil(provider) and Code.ensure_loaded?(provider) and
         function_exported?(provider, :answered_approval, 2) do
      case provider.answered_approval(source, request_id) do
        {:ok, record} when is_map(record) -> {:ok, record}
        _ -> {:error, :approval_evidence_unavailable}
      end
    else
      {:error, :approval_evidence_unavailable}
    end
  rescue
    _ -> {:error, :approval_evidence_unavailable}
  catch
    _, _ -> {:error, :approval_evidence_unavailable}
  end

  # A committed answer is useful evidence even when its responder lacks an
  # owner-bound human proof. It cannot satisfy the human graduation threshold.
  defp record_answer_evidence(record) do
    case resolve_tracking_prefix(record.resource_uri) do
      nil ->
        :ok

      prefix ->
        entry = get_or_create(record.agent_id, prefix)
        approved? = record.decision == :approve
        human? = Map.has_key?(record, :verified_human_id)

        updated =
          Map.merge(entry, %{
            approvals: entry.approvals + if(approved?, do: 1, else: 0),
            rejections: entry.rejections + if(approved?, do: 0, else: 1),
            unknown_approvals:
              entry.unknown_approvals + if(approved? and not human?, do: 1, else: 0),
            unknown_rejections:
              entry.unknown_rejections + if(not approved? and not human?, do: 1, else: 0),
            verified_human_approvals:
              entry.verified_human_approvals + if(approved? and human?, do: 1, else: 0),
            streak: if(approved?, do: entry.streak + 1, else: 0),
            human_streak: if(approved? and human?, do: entry.human_streak + 1, else: 0),
            graduated: false,
            graduated_at: nil,
            last_confirmation: DateTime.utc_now()
          })

        updated = updated |> GraduationCore.invalidate() |> maybe_suggest(record.agent_id, prefix)

        :ets.insert(@table, {{record.agent_id, prefix}, updated})

        emit_answer_evidence(record, prefix, updated, approved?, human?)
    end
  end

  defp emit_answer_evidence(record, prefix, updated, approved?, human?) do
    safe_emit(:confirmation_recorded, %{
      agent_id: record.agent_id,
      uri_prefix: prefix,
      source: record.source,
      request_id: record.request_id,
      action: if(approved?, do: :approval, else: :rejection),
      responder: if(human?, do: :verified_human, else: :unknown),
      streak: updated.streak,
      graduated: updated.graduated
    })
  end

  defp authorize_graduation(agent_id, operation, opts) do
    with {:ok, proof} <- GraduationCore.valid_options(opts, operation),
         :ok <-
           Arbor.Security.authorize_trust_graduation(
             proof.caller_id,
             agent_id,
             proof.session_token,
             operation
           ) do
      {:ok, proof}
    end
  end

  defp graduation_inputs(agent_id, prefix, entry) do
    case Store.get_profile(agent_id) do
      {:ok, profile} -> {profile, profile_eligibility(profile, prefix, entry)}
      _ -> {nil, GraduationCore.unavailable(:profile_unavailable, threshold_for(prefix))}
    end
  catch
    :exit, _ -> {nil, GraduationCore.unavailable(:profile_unavailable, threshold_for(prefix))}
  end

  defp profile_eligibility(profile, prefix, entry) do
    threshold = threshold_for(prefix)

    with {:ok, policy} <- PolicyHost.snapshot(),
         capability when not is_nil(capability) <-
           Enum.find(policy.capability_profiles, &(&1.uri_prefix == prefix)) do
      GraduationCore.eligibility(
        entry,
        prefix,
        profile,
        policy,
        threshold,
        CapabilityRiskProfiles.graduation_threshold(capability),
        capability
      )
    else
      _ -> GraduationCore.unavailable(:policy_unavailable, threshold)
    end
  end

  defp show_graduation(agent_id, prefix, entry) do
    {_profile, eligibility} = graduation_inputs(agent_id, prefix, entry)
    GraduationCore.show(agent_id, prefix, entry, eligibility)
  end

  defp maybe_suggest(entry, agent_id, prefix) do
    {profile, eligibility} = graduation_inputs(agent_id, prefix, entry)
    id = "graduation_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    updated = GraduationCore.suggest(entry, eligibility, profile, id, DateTime.utc_now())

    if updated.graduated,
      do:
        safe_emit(
          :graduation_suggested,
          GraduationCore.show(agent_id, prefix, updated, eligibility)
        )

    updated
  end

  defp perform_graduation_effects([], _agent_id, _prefix, _entry, _profile, _proof), do: :ok

  defp perform_graduation_effects(
         [:persist_auto_rule],
         agent_id,
         prefix,
         entry,
         expected_profile,
         proof
       ) do
    result =
      Store.update_profile(agent_id, fn profile ->
        with true <- profile == expected_profile,
             :ok <-
               Arbor.Security.authorize_trust_graduation(
                 proof.caller_id,
                 agent_id,
                 proof.session_token,
                 :accept
               ),
             eligibility <- profile_eligibility(profile, prefix, entry),
             {:ok, _, [:persist_auto_rule]} <-
               GraduationCore.decide(entry, proof.suggestion_id, eligibility, profile, :accept) do
          %{profile | rules: Map.put(profile.rules, prefix, :auto)}
        else
          false -> {:error, :profile_changed}
          {:error, _} = error -> error
        end
      end)

    case result do
      {:ok, _profile} -> :ok
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :graduation_store_outcome_unknown}
  end

  defp configured_thresholds do
    config = Application.get_env(:arbor_trust, :graduation_thresholds, %{})

    CapabilityRiskProfiles.graduation_thresholds()
    |> Map.merge(config)
  end

  defp resolve_threshold(thresholds, uri_prefix) do
    # Longest-prefix match against threshold keys
    thresholds
    |> Enum.filter(fn {prefix, _} -> CapabilityUri.prefix_match?(prefix, uri_prefix) end)
    |> case do
      [] -> @fallback_threshold
      matches -> matches |> Enum.max_by(fn {prefix, _} -> byte_size(prefix) end) |> elem(1)
    end
  end

  defp safe_emit(type, data) do
    Arbor.Signals.emit(:trust, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
