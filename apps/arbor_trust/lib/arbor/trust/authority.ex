defmodule Arbor.Trust.Authority do
  @moduledoc """
  Pure CRC module for trust authority operations.

  Centralizes pure trust logic: profile rule evaluation and profile mutations.
  GenServer wrappers (Manager, Store) call these functions for the actual logic.

  ## CRC Pattern

  - **Construct**: `new_profile/1` — create a trust profile with preset rules
  - **Reduce**: `freeze/2`, `unfreeze/1`, `set_rule/3` — pure state transitions
  - **Convert**: `effective_mode/3`, `explain/3`, `show_summary/1` — formatted output

  All functions are pure — no ETS, no GenServer calls, no side effects.
  """

  alias Arbor.Contracts.Trust.Profile

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Create a new trust profile with the default (cautious) preset rules.

  This is the single entry point for profile creation — it resolves the
  preset (baseline + rules) and applies it.
  """
  @spec new_profile(String.t()) :: Profile.t()
  def new_profile(agent_id) do
    {:ok, profile} = Profile.new(agent_id)
    {baseline, rules} = preset_rules(:cautious)

    %{
      profile
      | baseline: baseline,
        rules: rules,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
    }
  end

  # ===========================================================================
  # Reduce — Freeze
  # ===========================================================================

  @doc "Freeze trust progression."
  @spec freeze(Profile.t(), atom() | String.t()) :: Profile.t()
  def freeze(%Profile{} = profile, reason) do
    %{profile | frozen: true, frozen_reason: reason, frozen_at: DateTime.utc_now()}
  end

  @doc "Unfreeze trust progression."
  @spec unfreeze(Profile.t()) :: Profile.t()
  def unfreeze(%Profile{} = profile) do
    %{profile | frozen: false, frozen_reason: nil, frozen_at: nil}
  end

  @doc """
  Apply a named preset's baseline and rules to a profile, replacing the
  existing baseline and merging the preset rules over current rules.

  Use this for explicit reset operations (e.g., a user-initiated
  "reset to defaults"). Preset names: `:cautious`, `:balanced`, `:hands_off`,
  `:full_trust`.
  """
  @spec apply_preset(Profile.t(), atom()) :: Profile.t()
  def apply_preset(%Profile{} = profile, preset) do
    {baseline, rules} = preset_rules(preset)

    %{profile | baseline: baseline, rules: Map.merge(profile.rules, rules)}
  end

  # ===========================================================================
  # Reduce — Profile Rules
  # ===========================================================================

  @doc "Set a specific URI rule on the profile."
  @spec set_rule(Profile.t(), String.t(), atom()) :: Profile.t()
  def set_rule(%Profile{} = profile, uri_prefix, mode)
      when mode in [:block, :ask, :allow, :auto] do
    %{profile | rules: Map.put(profile.rules, warn_and_canonicalize_rule(uri_prefix), mode)}
  end

  # A trust rule with a glob (/** or /*) is a dead literal (see
  # Arbor.Contracts.Security.TrustRule): trust rules match by PREFIX, not glob, so
  # it silently never fires. Warn loudly + canonicalize to the bare prefix the
  # matcher actually uses, rather than storing a rule that vanishes to baseline.
  defp warn_and_canonicalize_rule(uri) do
    if Arbor.Contracts.Security.TrustRule.glob?(uri) do
      require Logger

      Logger.warning(
        "[Trust.Authority] set_rule: trust rule #{inspect(uri)} contains a glob; trust rules " <>
          "match by PREFIX not glob. Canonicalizing to the bare prefix."
      )

      canonical_trust_prefix(uri)
    else
      uri
    end
  end

  @doc "Remove a specific URI rule (falls back to baseline)."
  @spec remove_rule(Profile.t(), String.t()) :: Profile.t()
  def remove_rule(%Profile{} = profile, uri_prefix) do
    %{profile | rules: Map.delete(profile.rules, uri_prefix)}
  end

  # ===========================================================================
  # Convert — Mode Resolution
  # ===========================================================================

  @doc """
  Resolve effective mode for a resource URI.

  3-layer resolution (most restrictive wins):
  1. User preference (longest-prefix match in profile rules)
  2. Security ceiling (system-enforced maximums)
  3. Model constraint (optional per-model-class ceiling)
  """
  @spec effective_mode(Profile.t(), String.t(), keyword()) :: :block | :ask | :allow | :auto
  def effective_mode(%Profile{} = profile, resource_uri, opts \\ []) do
    # Layer 1: User preference. Infrastructure URIs (an agent discovering its OWN
    # tools) default to :auto when the profile has no matching rule — listing tools
    # grants no access (execution still needs caps), and requiring approval both
    # spams the owner and blocks the agent from functioning. An explicit profile
    # rule still overrides (resolve_prefix returns it); ceilings + model constraints
    # below still apply (most-restrictive wins).
    layer1_default = if infrastructure_auto?(resource_uri), do: :auto, else: profile.baseline
    user_mode = resolve_prefix(profile.rules, resource_uri, layer1_default)

    # Layer 2: Security ceilings
    ceilings = Keyword.get(opts, :security_ceilings, default_security_ceilings())
    ceiling_mode = resolve_prefix(ceilings, resource_uri, :auto)

    # Layer 3: Model constraints
    model_constraints = profile.model_constraints || %{}
    model_class = Keyword.get(opts, :model_class)

    model_mode =
      if model_class do
        resolve_model_constraint(model_constraints, model_class, resource_uri)
      else
        :auto
      end

    # Most restrictive wins
    most_restrictive([user_mode, ceiling_mode, model_mode])
  end

  @doc "Explain the mode resolution chain for debugging."
  @spec explain(Profile.t(), String.t(), keyword()) :: map()
  def explain(%Profile{} = profile, resource_uri, opts \\ []) do
    ceilings = Keyword.get(opts, :security_ceilings, default_security_ceilings())
    model_class = Keyword.get(opts, :model_class)

    layer1_default = if infrastructure_auto?(resource_uri), do: :auto, else: profile.baseline
    user_mode = resolve_prefix(profile.rules, resource_uri, layer1_default)
    ceiling_mode = resolve_prefix(ceilings, resource_uri, :auto)

    model_mode =
      if model_class do
        resolve_model_constraint(profile.model_constraints || %{}, model_class, resource_uri)
      else
        :auto
      end

    %{
      resource_uri: resource_uri,
      effective_mode: most_restrictive([user_mode, ceiling_mode, model_mode]),
      user_mode: user_mode,
      ceiling_mode: ceiling_mode,
      model_mode: model_mode,
      baseline: profile.baseline,
      matching_rule: find_matching_rule(profile.rules, resource_uri)
    }
  end

  # URIs that are pure infrastructure for an agent's own operation — they grant no
  # access on their own, so requiring approval only breaks the agent and spams the
  # owner. These default to :auto (Layer 1) unless the profile sets an explicit
  # rule. Discovering one's own tools is the canonical case (arbor://agent/
  # discover_tools); execution of any discovered tool still requires its capability.
  @infrastructure_auto_prefixes ["arbor://agent/discover_tools"]

  @spec infrastructure_auto?(String.t()) :: boolean()
  defp infrastructure_auto?(resource_uri) when is_binary(resource_uri) do
    Enum.any?(@infrastructure_auto_prefixes, &String.starts_with?(resource_uri, &1))
  end

  defp infrastructure_auto?(_), do: false

  # ===========================================================================
  # Convert — Display
  # ===========================================================================

  @doc "Format a trust summary for dashboard display."
  @spec show_summary(Profile.t()) :: map()
  def show_summary(%Profile{} = profile) do
    %{
      agent_id: profile.agent_id,
      frozen: profile.frozen,
      baseline: profile.baseline,
      rule_count: map_size(profile.rules)
    }
  end

  @doc """
  Serialize a Profile to a JSON-safe map for persistence.

  Converts DateTime fields to ISO8601 strings. The result is suitable for
  storage in JSONB columns or any backend that needs JSON-serializable data.

  Pair with `from_persistence/1` to round-trip.
  """
  @spec for_persistence(Profile.t()) :: map()
  def for_persistence(%Profile{} = profile) do
    profile
    |> Map.from_struct()
    |> Map.update(:rules, %{}, &(&1 || %{}))
    |> Map.update(:created_at, nil, &maybe_to_iso8601/1)
    |> Map.update(:updated_at, nil, &maybe_to_iso8601/1)
    |> Map.update(:last_activity_at, nil, &maybe_to_iso8601/1)
    |> Map.update(:frozen_at, nil, &maybe_to_iso8601/1)
  end

  @doc """
  Deserialize a Profile from a persistence map (e.g. loaded from Postgres).

  Handles both atom-keyed and string-keyed maps. Restores DateTime fields,
  coerces rule modes to atoms via `safe_mode/1`, and falls back to defaults
  for missing fields. Returns `{:ok, profile}` or `{:error, :invalid_data}`.

  Pair with `for_persistence/1` for round-trip.
  """
  @spec from_persistence(map()) :: {:ok, Profile.t()} | {:error, :invalid_data}
  def from_persistence(data) when is_map(data) do
    agent_id = data[:agent_id] || data["agent_id"]

    if agent_id do
      {:ok, profile} = Profile.new(agent_id)

      profile =
        Enum.reduce(data, profile, fn
          {k, v}, acc when is_binary(k) ->
            atom_key = safe_to_existing_atom(k)
            if atom_key && Map.has_key?(acc, atom_key), do: %{acc | atom_key => v}, else: acc

          {k, v}, acc when is_atom(k) ->
            if Map.has_key?(acc, k), do: %{acc | k => v}, else: acc
        end)

      # Restore DateTime fields
      profile = %{
        profile
        | created_at: maybe_parse_datetime(profile.created_at),
          updated_at: maybe_parse_datetime(profile.updated_at),
          last_activity_at: maybe_parse_datetime(profile.last_activity_at),
          frozen_at: maybe_parse_datetime(profile.frozen_at)
      }

      # Ensure rules keys are strings and modes are valid atoms
      rules =
        for {k, v} <- profile.rules || %{}, into: %{} do
          {to_string(k), safe_mode(v)}
        end

      # Normalize the top-level mode field too — JSON persistence round-trips
      # it as a string, and a string `baseline` slipped past the security
      # ceiling check until 2026-04-07 because `most_restrictive` couldn't
      # compare it with the atom ceilings.
      profile = %{
        profile
        | rules: rules,
          baseline: safe_mode(profile.baseline)
      }

      {:ok, profile}
    else
      {:error, :invalid_data}
    end
  end

  def from_persistence(_), do: {:error, :invalid_data}

  # ===========================================================================
  # Pure Helpers
  # ===========================================================================

  @doc "Get baseline and rules for a preset name."
  @spec preset_rules(atom()) :: {atom(), map()}
  def preset_rules(:cautious) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :block,
       "arbor://fs/read" => :auto,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       # A1: proactive notify is allowed by default (the agent can surface
       # progress/thoughts from first boot), bounded by a rate-limit constraint
       # as the anti-spam budget. The user dials block/ask in their profile.
       "arbor://comms/notify/session" => :allow,
       "arbor://shell" => :block,
       "arbor://shell/exec" => :ask
     }}
  end

  def preset_rules(:balanced) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :ask,
       "arbor://fs/read" => :auto,
       "arbor://fs/write" => :allow,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://comms/notify/session" => :allow,
       "arbor://shell" => :ask,
       "arbor://memory" => :auto
     }}
  end

  def preset_rules(:hands_off) do
    {:allow,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :auto,
       "arbor://fs" => :auto,
       "arbor://historian" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://memory" => :auto,
       "arbor://shell" => :ask,
       "arbor://governance" => :ask
     }}
  end

  def preset_rules(:full_trust) do
    {:auto,
     %{
       "arbor://shell" => :ask,
       "arbor://governance" => :ask
     }}
  end

  def preset_rules(_), do: preset_rules(:cautious)

  @doc """
  Most restrictive mode from a list.

  Normalizes string-form modes (`"allow"`, `"ask"`, `"block"`, `"auto"`)
  to their atom equivalents before comparing — historical persistence
  paths sometimes hand back string baselines, and we don't want a stray
  string slipping past the security ceilings because `Enum.min_by`
  preserved its original (non-atom) shape.
  """
  @spec most_restrictive([atom() | String.t()]) :: atom()
  def most_restrictive(modes) do
    modes
    |> Enum.map(&normalize_mode/1)
    |> Enum.min_by(&mode_index/1)
  end

  @doc false
  @spec normalize_mode(atom() | String.t() | term()) :: atom()
  def normalize_mode(mode) when is_atom(mode), do: mode
  def normalize_mode("block"), do: :block
  def normalize_mode("ask"), do: :ask
  def normalize_mode("allow"), do: :allow
  def normalize_mode("auto"), do: :auto
  # Unknown / garbage modes default to :ask — fail safe.
  def normalize_mode(_), do: :ask

  # ===========================================================================
  # Private
  # ===========================================================================

  defp resolve_prefix(rules, uri, baseline) when is_map(rules) do
    # Longest prefix match
    matching =
      rules
      |> Enum.filter(fn {prefix, _mode} -> prefix_matches?(uri, prefix) end)
      |> Enum.sort_by(fn {prefix, mode} ->
        {-String.length(canonical_trust_prefix(prefix)), mode_index(mode)}
      end)

    case matching do
      [{_prefix, mode} | _] -> mode
      [] -> baseline
    end
  end

  defp resolve_prefix(_, _, baseline), do: baseline

  defp resolve_model_constraint(constraints, model_class, uri) do
    matching =
      constraints
      |> Enum.filter(fn
        {{class, prefix}, _mode} ->
          class == model_class and prefix_matches?(uri, prefix)

        _ ->
          false
      end)
      |> Enum.sort_by(fn {{_, prefix}, _} -> -String.length(prefix) end)

    case matching do
      [{{_, _}, mode} | _] -> mode
      [] -> :auto
    end
  end

  defp find_matching_rule(rules, uri) do
    rules
    |> Enum.filter(fn {prefix, _} -> prefix_matches?(uri, prefix) end)
    |> Enum.sort_by(fn {prefix, _} -> -String.length(prefix) end)
    |> List.first()
  end

  # Trust rules match by URI PREFIX, not glob. A trailing "/**" or "/*" is natural to write
  # (capabilities use it for path scope) but here it is a literal that matches nothing, silently
  # disabling the rule. Strip it so the rule covers the subtree its author intended. Canonicalizing
  # at MATCH time (not on write) covers every rule-write path; ceilings are bare so they're unchanged.
  defp canonical_trust_prefix(prefix) do
    prefix
    |> String.replace_suffix("/**", "")
    |> String.replace_suffix("/*", "")
  end

  defp prefix_matches?(uri, prefix) do
    prefix = canonical_trust_prefix(prefix)
    uri == prefix or String.starts_with?(uri, prefix <> "/")
  end

  defp mode_index(:block), do: 0
  defp mode_index(:ask), do: 1
  defp mode_index(:allow), do: 2
  defp mode_index(:auto), do: 3
  # Unknown / non-atom modes are treated as `:ask` (rank 1) — fail safe.
  # Callers should normalize via `normalize_mode/1` first so this branch is
  # only ever reached for genuinely unknown atoms.
  defp mode_index(_), do: 1

  defp default_security_ceilings do
    %{
      "arbor://shell" => :ask,
      "arbor://governance" => :ask
    }
  end

  # ── Persistence helpers (used by for_persistence/from_persistence) ─────────

  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_to_iso8601(other), do: other

  defp maybe_parse_datetime(nil), do: nil
  defp maybe_parse_datetime(%DateTime{} = dt), do: dt

  defp maybe_parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp maybe_parse_datetime(_), do: nil

  defp safe_mode(v) when v in [:block, :ask, :allow, :auto], do: v
  defp safe_mode("block"), do: :block
  defp safe_mode("ask"), do: :ask
  defp safe_mode("allow"), do: :allow
  defp safe_mode("auto"), do: :auto
  defp safe_mode(_), do: :ask

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
