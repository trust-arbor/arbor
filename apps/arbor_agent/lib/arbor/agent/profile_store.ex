defmodule Arbor.Agent.ProfileStore.MutationResult do
  @moduledoc """
  Bounded typed result of `Arbor.Agent.ProfileStore.apply_authority_mutation/2`.

  `outcome` is one of:

    * `:applied`         — the backend acknowledged the CAS and the returned
                           successor validated as the exact intended record.
    * `:not_applied`     — reobservation proved the state is unchanged since the
                           snapshot (the CAS did not land).
    * `:already_applied` — reobservation proved the exact intended one-revision
                           successor is present.
    * `:conflict`        — reobservation showed a valid divergent or later
                           record (or the slot is absent).
    * `:outcome_unknown` — reobservation was unreadable; the caller (C3C) owns
                           retry/recovery.

  `record` carries the relevant authoritative Record when one was reobserved
  (`nil` for `:outcome_unknown` and absent-slot `:conflict`).
  """

  use TypedStruct

  alias Arbor.Contracts.Persistence.Record

  @type outcome ::
          :applied | :not_applied | :already_applied | :conflict | :outcome_unknown

  typedstruct do
    @typedoc "Bounded typed result of an authority mutation CAS attempt."

    field(:outcome, outcome(), enforce: true)
    field(:record, Record.t() | nil, default: nil)
  end
end

defmodule Arbor.Agent.ProfileStore do
  @moduledoc """
  Durable profile storage backed by `Arbor.Persistence.BufferedStore`.

  Provides ETS-cached reads with pluggable durable persistence (Postgres by
  default, ETS-only in tests). Profiles are stored as serialized maps wrapped
  in `%Record{}` structs.

  ## Dual-Read Fallback

  `load_profile/1` tries the store first, then falls back to the legacy
  `.arbor/agents/*.agent.json` files. On fallback hit, the profile is
  lazy-migrated into the store so subsequent reads are fast.

  ## Supervision

  Started as a `BufferedStore` child in `Arbor.Agent.Application`.
  The store name is `:arbor_agent_profiles`.
  """

  alias Arbor.Agent.Profile
  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  require Logger

  @store_name :arbor_agent_profiles
  @legacy_dir ".arbor/agents"
  @max_agent_id_bytes 256
  @max_record_id_bytes 256
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @authority_snapshot_keys [
    "agent_id",
    "template",
    "initial_capabilities",
    "metadata",
    "version",
    :agent_id,
    :template,
    :initial_capabilities,
    :metadata,
    :version
  ]

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Store an agent profile.

  Serializes the profile and persists via BufferedStore (ETS + backend).
  """
  @spec store_profile(Profile.t()) :: :ok | {:error, term()}
  def store_profile(%Profile{agent_id: agent_id} = profile) do
    if available?() do
      record =
        Record.new(agent_id, Profile.serialize(profile), id: "agent_profile:#{agent_id}")

      BufferedStore.put(agent_id, record, name: @store_name)
    else
      {:error, :store_unavailable}
    end
  end

  @doc """
  Update a single field under `profile.metadata[:last_model_config]`,
  preserving the rest of the metadata.

  Used by the `/model`, `/runtime`, and `/fallback` slash commands to
  persist a per-session edit to the agent's profile so it survives
  restarts. `Lifecycle.resolve_agent_runtime/2` and
  `resolve_fallback_chain/2` read from this same `last_model_config`
  map at create/resume time.

  Returns `:ok` on success, `{:error, reason}` if the profile isn't
  found or the store is unavailable. Callers typically log warnings on
  failure rather than failing the user-visible command — the live
  session edit is the source of truth for the current turn.
  """
  @spec put_model_config_value(String.t(), atom(), term()) :: :ok | {:error, term()}
  def put_model_config_value(agent_id, key, value)
      when is_binary(agent_id) and is_atom(key) do
    with {:ok, profile} <- load_profile(agent_id) do
      metadata = profile.metadata || %{}
      last_config = Map.get(metadata, :last_model_config) || %{}
      new_last_config = Map.put(last_config, key, value)
      updated_metadata = Map.put(metadata, :last_model_config, new_last_config)
      updated_profile = %{profile | metadata: updated_metadata}
      store_profile(updated_profile)
    end
  end

  @doc """
  Load an agent profile by ID.

  Tries the store first, falls back to legacy JSON file. On fallback hit,
  lazy-migrates the profile into the store.
  """
  @spec load_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found | term()}
  def load_profile(agent_id) when is_binary(agent_id) do
    case load_from_store(agent_id) do
      {:ok, _profile} = ok ->
        ok

      {:error, :not_found} ->
        load_from_json_fallback(agent_id)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read-only profile load for readiness projections.

  Tries the store first, then reads a legacy JSON file if present, but never
  migrates into the store, never deletes the legacy file, and never persists.
  """
  @spec load_profile_readonly(String.t()) :: {:ok, Profile.t()} | {:error, :not_found | term()}
  def load_profile_readonly(agent_id) when is_binary(agent_id) do
    case load_from_store(agent_id) do
      {:ok, _profile} = ok ->
        ok

      {:error, :not_found} ->
        read_json_profile(agent_id)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read the persisted authority fields without applying `Profile.deserialize/1`
  defaults.

  This is the read-only authority-inspection boundary. It preserves whether
  persisted fields are absent so fail-closed callers can distinguish missing
  authority state from explicit empty/default values, while excluding unrelated
  profile fields from the result. Like
  `load_profile_readonly/1`, it never migrates, deletes, or persists.
  """
  @spec load_profile_authority_readonly(String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def load_profile_authority_readonly(agent_id) when is_binary(agent_id) do
    case load_serialized_from_store(agent_id) do
      {:ok, serialized} ->
        {:ok, Map.take(serialized, @authority_snapshot_keys)}

      {:error, :not_found} ->
        with {:ok, serialized} <- read_json_profile_map(agent_id) do
          {:ok, Map.take(serialized, @authority_snapshot_keys)}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all stored profiles.

  Returns profiles from the BufferedStore ETS cache.
  Falls back to legacy JSON scan if the store is unavailable.
  """
  @spec list_profiles() :: [Profile.t()]
  def list_profiles do
    if available?() do
      {:ok, keys} = BufferedStore.list(name: @store_name)

      keys
      |> Enum.map(&load_from_store/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, profile} -> profile end)
    else
      list_from_json_fallback()
    end
  end

  @doc """
  List all profiles with `auto_start: true`.
  """
  @spec list_auto_start_profiles() :: [Profile.t()]
  def list_auto_start_profiles do
    list_profiles()
    |> Enum.filter(& &1.auto_start)
  end

  @doc """
  Delete a profile from the store.
  """
  @spec delete_profile(String.t()) :: :ok
  def delete_profile(agent_id) when is_binary(agent_id) do
    if available?() do
      BufferedStore.delete(agent_id, name: @store_name)
    end

    # Also remove legacy JSON file if it exists
    path = legacy_profile_path(agent_id)
    File.rm(path)

    :ok
  end

  @doc """
  Check if the ProfileStore is running.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  end

  @doc """
  Migrate legacy JSON profiles into the store.

  Scans `.arbor/agents/*.agent.json` and stores any profiles not already
  present in the BufferedStore. Idempotent — safe to call multiple times.
  """
  @spec migrate_json_profiles() :: {:ok, non_neg_integer()}
  def migrate_json_profiles do
    if available?() do
      do_migrate_json_profiles()
    else
      {:ok, 0}
    end
  end

  # ── Authority mutation (Phase 4C C3B1) ──────────────────────────────
  #
  # Internal Agent-owned authoritative snapshot + acknowledged generation/
  # revision CAS over the fixed :arbor_agent_profiles store. Reserved for the
  # C3C reconciliation worker; NOT a Jido action, MCP tool, public operator
  # endpoint, or Arbor.Agent facade exposure.
  #
  # Legacy/ephemeral/insufficient-durability authority stays read-only: the
  # durability gate fails closed before any mutation read or write, and the
  # snapshot never uses cache-only get, Profile.deserialize defaults, legacy
  # JSON fallback, lazy migration, or caller-selected store/backend authority.

  @doc """
  Return the exact authoritative profile Record for mutation-eligible callers.

  Admits mutation only when the fixed `:arbor_agent_profiles` store attests a
  `:node_restart` configured backend, then authoritatively reads the durable
  Record (never the cache) and returns it with its backend-owned generation +
  revision. A legacy-only or absent profile returns `{:error, :not_found}`;
  ephemeral/insufficient-durability stores return `{:error,
  :authority_not_durable}` before any read.
  """
  @spec authority_mutation_snapshot(String.t()) ::
          {:ok, Record.t()} | {:error, term()}
  def authority_mutation_snapshot(agent_id) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- attest_mutation_authority() do
      authoritative_profile_get(agent_id)
    end
  end

  @doc """
  Apply a closed authority mutation via an acknowledged compare-and-swap fenced
  on the exact observed Record generation + revision.

  `observed` is the Record returned by `authority_mutation_snapshot/1`.
  `governed` is the closed authority update (`template`, `initial_capabilities`,
  `metadata.template_authority_policy`, and `metadata.template_source`) prepared
  verbatim by `ProfileAuthorityMutationCore.prepare/2`. Only those four fields
  are overwritten; every unrelated top-level and nested metadata field,
  including `metadata.exact_template_policy`, plus the Record logical
  id/key/metadata and all backend fences are preserved until the backend
  advances them.

  Before CAS the shell authoritatively re-reads the current Record and requires
  the full envelope (id/key/data/metadata/generation/revision) to equal the
  caller's ORIGINAL snapshot; drift or token-preserving tamper is a `:conflict`
  with no CAS attempted. The CAS linearization point fences on the observed
  Record's generation + revision. On an ambiguous outcome the shell performs
  exactly ONE authoritative reobservation and classifies it; it never hides a
  `:not_applied` behind an internal retry (C3C owns retry decisions).
  """
  @spec apply_authority_mutation(Record.t(), map()) ::
          {:ok, __MODULE__.MutationResult.t()} | {:error, term()}
  def apply_authority_mutation(%Record{} = observed, governed) do
    with :ok <- validate_observed_record(observed),
         :ok <- attest_mutation_authority(),
         {:ok, intended_data} <- prepare_intended(observed.data, governed) do
      replacement = %{observed | data: intended_data}

      case stability_check(observed) do
        {:stable, _current} ->
          apply_authority_cas(observed, intended_data, replacement)

        {:conflict, record} ->
          {:ok, %__MODULE__.MutationResult{outcome: :conflict, record: record}}

        {:outcome_unknown} ->
          {:ok, %__MODULE__.MutationResult{outcome: :outcome_unknown, record: nil}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def apply_authority_mutation(_observed, _governed), do: {:error, :invalid_request}

  defp do_migrate_json_profiles do
    dir = legacy_agents_dir()

    case File.ls(dir) do
      {:ok, files} ->
        count =
          files
          |> Enum.filter(&String.ends_with?(&1, ".agent.json"))
          |> Enum.reject(&profile_exists_in_store?/1)
          |> Enum.count(&migrate_single_profile/1)

        {:ok, count}

      {:error, _} ->
        {:ok, 0}
    end
  end

  defp profile_exists_in_store?(file) do
    agent_id = String.replace_suffix(file, ".agent.json", "")
    BufferedStore.exists?(agent_id, name: @store_name)
  end

  defp migrate_single_profile(file) do
    agent_id = String.replace_suffix(file, ".agent.json", "")

    case read_json_profile(agent_id) do
      {:ok, profile} ->
        store_profile(profile)
        true

      {:error, _} ->
        false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp load_from_store(agent_id) do
    with {:ok, data} <- load_serialized_from_store(agent_id) do
      Profile.deserialize(data)
    end
  end

  defp load_serialized_from_store(agent_id) do
    if available?() do
      case BufferedStore.get(agent_id, name: @store_name) do
        {:ok, raw} ->
          case unwrap_record(raw) do
            data when is_map(data) and not is_struct(data) -> {:ok, data}
            _other -> {:error, :invalid_profile_record}
          end

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  defp load_from_json_fallback(agent_id) do
    case read_json_profile(agent_id) do
      {:ok, profile} ->
        Logger.warning(
          "[ProfileStore] Migrating legacy JSON profile for #{agent_id} — " <>
            "JSON profiles are deprecated, use BufferedStore (Postgres)"
        )

        # Lazy-migrate into store and remove JSON file
        if available?() do
          store_profile(profile)
          path = legacy_profile_path(agent_id)
          File.rm(path)
        end

        {:ok, profile}

      {:error, _} = error ->
        error
    end
  end

  defp read_json_profile(agent_id) do
    with {:ok, map} <- read_json_profile_map(agent_id) do
      Profile.deserialize(map)
    end
  end

  defp read_json_profile_map(agent_id) do
    path = legacy_profile_path(agent_id)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, :invalid_profile_json}
          {:error, _} = error -> error
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp list_from_json_fallback do
    dir = legacy_agents_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".agent.json"))
        |> Enum.map(fn file ->
          agent_id = String.replace_suffix(file, ".agent.json", "")
          read_json_profile(agent_id)
        end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, profile} -> profile end)

      {:error, _} ->
        []
    end
  end

  # Record struct from backend (loaded from disk after restart)
  defp unwrap_record(%Record{data: data}), do: data
  # Plain map from ETS (stored during current session)
  defp unwrap_record(%{} = data), do: data

  # ── Authority mutation helpers ──────────────────────────────────────

  defp attest_mutation_authority do
    # Public Arbor.Persistence facade — callers cannot select store authority.
    case Arbor.Persistence.buffered_store_authority_mode(@store_name) do
      {:ok, {:backend, :node_restart}} ->
        :ok

      {:ok, _insufficient} ->
        {:error, :authority_not_durable}

      {:error, _reason} ->
        {:error, :authority_unavailable}

      _malformed ->
        {:error, :authority_unavailable}
    end
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    cond do
      byte_size(agent_id) > @max_agent_id_bytes ->
        {:error, :invalid_request}

      not String.valid?(agent_id) ->
        {:error, :invalid_request}

      String.contains?(agent_id, <<0>>) ->
        {:error, :invalid_request}

      not Regex.match?(@agent_id_re, agent_id) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp validate_agent_id(_), do: {:error, :invalid_request}

  defp validate_observed_record(%Record{} = observed) do
    with :ok <- validate_agent_id(observed.key),
         true <- plain_map?(observed.data),
         true <- plain_map?(observed.metadata),
         true <- is_integer(observed.generation) and observed.generation >= 1,
         true <- is_integer(observed.revision) and observed.revision >= 1,
         true <- valid_record_id?(observed.id) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_observed_record(_), do: {:error, :invalid_request}

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp valid_record_id?(id) do
    is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_record_id_bytes and
      String.valid?(id) and not String.contains?(id, <<0>>)
  end

  defp valid_optional_timestamp?(nil), do: true
  defp valid_optional_timestamp?(%DateTime{}), do: true
  defp valid_optional_timestamp?(_), do: false

  defp prepare_intended(observed_data, governed) do
    case ProfileAuthorityMutationCore.prepare(observed_data, governed) do
      {:ok, _intended} = ok ->
        ok

      {:error, _reason} ->
        {:error, :malformed_governed}
    end
  end

  # Authoritative read of the fixed store, decoded against the closed Record
  # envelope. A configured backend error never falls back to the cache.
  defp authoritative_profile_get(agent_id) do
    # Public Arbor.Persistence facade — a configured backend error never falls
    # back to the cache.
    case Arbor.Persistence.buffered_store_authoritative_get(@store_name, agent_id) do
      {:ok, record} ->
        decode_profile_record(record, agent_id)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_backend_record} ->
        {:error, :invalid_record}

      {:error, :invalid_backend_response} ->
        {:error, :invalid_record}

      {:error, _reason} ->
        {:error, :backend_unavailable}

      _malformed ->
        {:error, :backend_unavailable}
    end
  end

  defp decode_profile_record(%Record{} = record, agent_id) do
    with true <- record.key == agent_id,
         true <- plain_map?(record.data),
         true <- plain_map?(record.metadata),
         true <- is_integer(record.generation) and record.generation >= 1,
         true <- is_integer(record.revision) and record.revision >= 1,
         true <- valid_record_id?(record.id),
         true <- valid_optional_timestamp?(record.inserted_at),
         true <- valid_optional_timestamp?(record.updated_at) do
      {:ok, record}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp decode_profile_record(_other, _agent_id), do: {:error, :invalid_record}

  # Pre-CAS envelope stability: Record CAS fences on generation+revision only,
  # so first prove the full envelope is unchanged since observation. Drift or
  # a token-preserving tamper is a conflict with NO CAS attempted.
  defp stability_check(observed) do
    case authoritative_profile_get(observed.key) do
      {:ok, current} ->
        if ProfileAuthorityMutationCore.envelope_stable?(observed, current) do
          {:stable, current}
        else
          {:conflict, current}
        end

      {:error, :not_found} ->
        {:conflict, nil}

      {:error, :invalid_record} ->
        {:outcome_unknown}

      {:error, _reason} ->
        {:error, :backend_unavailable}
    end
  end

  defp apply_authority_cas(observed, intended_data, replacement) do
    # Public Arbor.Persistence facade — exactly ONE acknowledged CAS fenced on
    # the observed Record generation + revision.
    result =
      Arbor.Persistence.buffered_store_acknowledged_compare_and_swap(
        @store_name,
        observed.key,
        {:value, observed},
        replacement
      )

    case result do
      {:ok, successor} ->
        # Per the accepted design (C4): a successful CAS response must be
        # decoded against the FULL closed Record envelope (decode_profile_record/2
        # validates key/data/metadata are plain maps, generation/revision are
        # integers >= 1, a valid record id, AND valid inserted_at/updated_at)
        # BEFORE it may be reported :applied. Only a valid decoded Record that is
        # also the exact intended successor yields :applied; a malformed
        # successful backend response reobserves/classifies, never :applied.
        with {:ok, decoded} <- decode_profile_record(successor, observed.key),
             true <- successor_envelope?(observed, intended_data, decoded) do
          {:ok, %__MODULE__.MutationResult{outcome: :applied, record: decoded}}
        else
          _ -> reobserve_and_classify(observed, intended_data)
        end

      {:error, :conflict} ->
        reobserve_and_classify(observed, intended_data)

      {:error, :outcome_unknown} ->
        reobserve_and_classify(observed, intended_data)

      {:error, :key_mismatch} ->
        {:error, :invalid_request}

      {:error, :store_unavailable} ->
        {:error, :authority_unavailable}

      {:error, :unsupported} ->
        {:error, :backend_unavailable}

      {:error, _reason} ->
        {:error, :backend_unavailable}

      _malformed ->
        reobserve_and_classify(observed, intended_data)
    end
  end

  defp successor_envelope?(observed, intended_data, %Record{} = successor) do
    successor.id == observed.id and
      successor.key == observed.key and
      successor.generation == observed.generation and
      successor.revision == observed.revision + 1 and
      successor.data == intended_data and
      successor.metadata == observed.metadata
  end

  defp successor_envelope?(_observed, _intended_data, _successor), do: false

  # Exactly ONE authoritative reobservation; NO retry loop. C3C owns retry.
  defp reobserve_and_classify(observed, intended_data) do
    reobserved = normalize_reobserved(observed.key)

    outcome =
      ProfileAuthorityMutationCore.classify(observed, intended_data, reobserved)

    record =
      if outcome in [:not_applied, :already_applied, :conflict],
        do: reobserved_record(reobserved),
        else: nil

    {:ok, %__MODULE__.MutationResult{outcome: outcome, record: record}}
  end

  defp normalize_reobserved(key) do
    case authoritative_profile_get(key) do
      {:ok, %Record{key: ^key} = record} -> {:ok, record}
      {:ok, _other} -> {:error, :invalid_record}
      {:error, :not_found} -> :not_found
      {:error, :invalid_record} -> {:error, :invalid_record}
      {:error, _reason} -> {:error, :backend_unavailable}
    end
  end

  defp reobserved_record({:ok, %Record{} = record}), do: record
  defp reobserved_record(_), do: nil

  defp legacy_profile_path(agent_id) do
    Path.join(legacy_agents_dir(), "#{agent_id}.agent.json")
  end

  defp legacy_agents_dir do
    Path.join(File.cwd!(), @legacy_dir)
  end
end
