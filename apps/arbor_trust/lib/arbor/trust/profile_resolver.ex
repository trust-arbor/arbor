defmodule Arbor.Trust.ProfileResolver do
  @moduledoc """
  URI-prefix trust resolution engine.

  Resolves the effective trust mode for an agent performing an operation,
  using three layers:

  1. **User preference** — longest-prefix match in the agent's trust profile rules
  2. **Security ceiling** — system-enforced maximums that no user preference can override
  3. **Model constraint** — optional per-model-class ceiling

  The effective mode is the most restrictive of all three layers.

  ## Modes

  Four behavioral modes, ordered from most to least restrictive:

  - `:block` — hard deny, agent cannot use this capability
  - `:ask` — agent must get user confirmation each time
  - `:allow` — permitted, but user is notified
  - `:auto` — silent, just do it

  ## Examples

      iex> rules = %{"arbor://shell" => :block, "arbor://shell/exec/git" => :ask}
      iex> ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/git", :ask)
      :ask
      iex> ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/rm", :ask)
      :block

      iex> ProfileResolver.most_restrictive([:auto, :ask, :allow])
      :ask

      iex> ProfileResolver.effective_mode(%{rules: %{}, baseline: :ask}, "arbor://shell/exec/git")
      :ask
  """

  @type mode :: :block | :ask | :allow | :auto
  @type rules :: %{String.t() => mode()}

  @mode_order %{block: 0, ask: 1, allow: 2, auto: 3}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Resolve the effective trust mode for an agent and resource URI.

  Takes a profile map (or struct with `:rules`, `:baseline`, and optionally
  `:model_constraints` fields), the resource URI, and optional opts.

  ## Options

  - `:model_class` — atom identifying the model class (e.g., `:frontier_cloud`)
  - `:security_ceilings` — override security ceilings (default: from config)
  """
  @spec effective_mode(map(), String.t(), keyword()) :: mode()
  def effective_mode(profile, resource_uri, opts \\ []) do
    # Resolve security ceilings from config (Authority is pure — no config
    # access — so we inject the ceiling lookup here at the caller boundary).
    opts = Keyword.put_new_lazy(opts, :security_ceilings, &security_ceilings/0)

    profile
    |> ensure_profile_struct()
    |> Arbor.Trust.Authority.effective_mode(resource_uri, opts)
  end

  defp ensure_profile_struct(%Arbor.Contracts.Trust.Profile{} = profile), do: profile

  defp ensure_profile_struct(profile_map) when is_map(profile_map) do
    # Backward-compat: callers passing a generic map get coerced into a
    # partial Profile struct so Authority's pattern match succeeds.
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new("__profile_resolver_stub__")

    %{
      profile
      | baseline: Map.get(profile_map, :baseline, :ask),
        rules: Map.get(profile_map, :rules, %{}),
        model_constraints: Map.get(profile_map, :model_constraints, %{})
    }
  end

  @doc """
  Resolve the mode for a URI using longest-prefix match against a rules map.

  Returns the mode from the longest matching prefix, or the baseline if
  no prefix matches.

  ## Examples

      iex> rules = %{"arbor://shell" => :block, "arbor://shell/exec/git" => :ask}
      iex> ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/git", :auto)
      :ask
      iex> ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/rm", :auto)
      :block
      iex> ProfileResolver.resolve_prefix(rules, "arbor://memory/read", :auto)
      :auto
  """
  @spec resolve_prefix(rules(), String.t(), mode()) :: mode()
  def resolve_prefix(rules, uri, baseline) when is_map(rules) do
    rules
    |> Enum.filter(fn {prefix, _mode} -> String.starts_with?(uri, prefix) end)
    |> case do
      [] -> baseline
      matches -> matches |> Enum.max_by(fn {prefix, _} -> byte_size(prefix) end) |> elem(1)
    end
  end

  @doc """
  Return the most restrictive mode from a list.

  Ordering: block > ask > allow > auto

  ## Examples

      iex> ProfileResolver.most_restrictive([:auto, :ask, :allow])
      :ask
      iex> ProfileResolver.most_restrictive([:auto, :auto])
      :auto
      iex> ProfileResolver.most_restrictive([:block, :auto])
      :block
  """
  @spec most_restrictive([mode() | String.t() | nil]) :: mode()
  def most_restrictive(modes) do
    modes
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Arbor.Trust.Authority.normalize_mode/1)
    |> Enum.min_by(fn mode -> Map.get(@mode_order, mode, 3) end, fn -> :ask end)
  end

  @doc """
  Compare two modes. Returns true if `a` is at least as restrictive as `b`.

  ## Examples

      iex> ProfileResolver.at_least_as_restrictive?(:block, :ask)
      true
      iex> ProfileResolver.at_least_as_restrictive?(:auto, :ask)
      false
  """
  @spec at_least_as_restrictive?(mode() | String.t(), mode() | String.t()) :: boolean()
  def at_least_as_restrictive?(a, b) do
    a = Arbor.Trust.Authority.normalize_mode(a)
    b = Arbor.Trust.Authority.normalize_mode(b)
    Map.get(@mode_order, a, 3) <= Map.get(@mode_order, b, 3)
  end

  @doc """
  Explain the resolution chain for debugging.

  Returns a map showing how the effective mode was determined:
  user preference, security ceiling, model constraint, and final result.
  """
  @spec explain(map(), String.t(), keyword()) :: map()
  def explain(profile, resource_uri, opts \\ []) do
    rules = Map.get(profile, :rules, %{})
    baseline = Map.get(profile, :baseline, :ask)
    model_constraints = Map.get(profile, :model_constraints, %{})

    ceilings = Keyword.get(opts, :security_ceilings, security_ceilings())
    model_class = Keyword.get(opts, :model_class)

    user_mode = resolve_prefix(rules, resource_uri, baseline)
    security_ceiling = resolve_prefix(ceilings, resource_uri, :auto)
    model_ceiling = resolve_model_constraint(model_constraints, resource_uri, model_class)

    effective = most_restrictive([user_mode, security_ceiling, model_ceiling])

    # Find which rule matched
    user_match =
      rules
      |> Enum.filter(fn {prefix, _} -> String.starts_with?(resource_uri, prefix) end)
      |> Enum.max_by(fn {prefix, _} -> byte_size(prefix) end, fn -> nil end)

    ceiling_match =
      ceilings
      |> Enum.filter(fn {prefix, _} -> String.starts_with?(resource_uri, prefix) end)
      |> Enum.max_by(fn {prefix, _} -> byte_size(prefix) end, fn -> nil end)

    %{
      resource_uri: resource_uri,
      user_mode: user_mode,
      user_match: user_match,
      baseline: baseline,
      security_ceiling: security_ceiling,
      ceiling_match: ceiling_match,
      model_class: model_class,
      model_ceiling: model_ceiling,
      effective_mode: effective
    }
  end

  # ── Security Ceilings ──────────────────────────────────────────────

  @doc """
  Get the security ceilings map.

  Security ceilings are system-enforced maximums that no user preference
  can override. Loaded from application config.
  """
  @spec security_ceilings() :: rules()
  def security_ceilings do
    Application.get_env(:arbor_trust, :security_ceilings, default_security_ceilings())
  end

  @doc """
  Default security ceilings preserving existing invariants.

  Shell and governance always require at least `:ask`.

  The keys here are URI **prefixes** matched longest-first by
  `Authority.effective_mode/3`. Both the legacy short-namespace form
  (`arbor://shell`) and the canonical action-URI form
  (`arbor://actions/execute/shell.`) are listed because action
  authorization passes the canonical form (e.g.
  `arbor://actions/execute/shell.execute`) which would not match the
  short namespace alone — that mismatch produced a real security
  regression where shell.execute auto-ran without approval.
  """
  @spec default_security_ceilings() :: rules()
  def default_security_ceilings do
    %{
      # Shell — never auto, even for veteran agents.
      "arbor://shell" => :ask,
      "arbor://actions/execute/shell." => :ask,
      # Governance changes — never auto.
      "arbor://governance" => :ask,
      "arbor://actions/execute/governance." => :ask,
      # Defense in depth: code and filesystem writes need confirmation
      # even on the most trusting profiles. Reads remain unrestricted.
      # Without these, a veteran agent on the :hands_off preset can write
      # arbitrary code/files without prompting — that's an "I trust you"
      # ceiling that's too generous to be the default.
      "arbor://code/write" => :ask,
      "arbor://fs/write" => :ask,
      # Per-action canonical URIs. Listed precisely (not by prefix) so we
      # don't accidentally gate read operations like file.list / file.glob.
      "arbor://actions/execute/file.write" => :ask,
      "arbor://actions/execute/file.edit" => :ask,
      "arbor://actions/execute/code.compile_and_test" => :ask,
      "arbor://actions/execute/code.hot_load" => :ask
    }
  end

  # ── Presets ─────────────────────────────────────────────────────────

  @doc """
  Get a preset trust profile rules map by name.

  Presets are onboarding templates that initialize a trust profile.
  """
  @spec preset(atom()) :: %{baseline: mode(), rules: rules()}
  def preset(preset_name) do
    {baseline, rules} = Arbor.Trust.Authority.preset_rules(preset_name)
    %{baseline: baseline, rules: rules}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp resolve_model_constraint(_constraints, _uri, nil), do: nil

  defp resolve_model_constraint(constraints, uri, model_class) when is_map(constraints) do
    # Model constraints are keyed by {model_class, uri_prefix}
    constraints
    |> Enum.filter(fn
      {{mc, prefix}, _mode} -> mc == model_class and String.starts_with?(uri, prefix)
      _ -> false
    end)
    |> case do
      [] -> nil
      matches -> matches |> Enum.max_by(fn {{_, prefix}, _} -> byte_size(prefix) end) |> elem(1)
    end
  end

  defp resolve_model_constraint(_, _, _), do: nil
end
