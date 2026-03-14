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
    rules = Map.get(profile, :rules, %{})
    baseline = Map.get(profile, :baseline, :ask)
    model_constraints = Map.get(profile, :model_constraints, %{})

    # Layer 1: User preference (longest-prefix match)
    user_mode = resolve_prefix(rules, resource_uri, baseline)

    # Layer 2: Security ceiling (system-enforced)
    ceilings = Keyword.get(opts, :security_ceilings, security_ceilings())
    security_ceiling = resolve_prefix(ceilings, resource_uri, :auto)

    # Layer 3: Model constraint (optional)
    model_class = Keyword.get(opts, :model_class)
    model_ceiling = resolve_model_constraint(model_constraints, resource_uri, model_class)

    # Effective = most restrictive of all three
    most_restrictive([user_mode, security_ceiling, model_ceiling])
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
  @spec most_restrictive([mode()]) :: mode()
  def most_restrictive(modes) do
    modes
    |> Enum.reject(&is_nil/1)
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
  @spec at_least_as_restrictive?(mode(), mode()) :: boolean()
  def at_least_as_restrictive?(a, b) do
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
  """
  @spec default_security_ceilings() :: rules()
  def default_security_ceilings do
    %{
      "arbor://shell" => :ask,
      "arbor://governance" => :ask
    }
  end

  # ── Presets ─────────────────────────────────────────────────────────

  @doc """
  Get a preset trust profile rules map by name.

  Presets are onboarding templates that initialize a trust profile.
  """
  @spec preset(atom()) :: %{baseline: mode(), rules: rules()}
  def preset(:cautious) do
    %{
      baseline: :ask,
      rules: %{
        # Orchestrator required for all agents to function
        "arbor://orchestrator" => :auto,
        # Reads are frictionless
        "arbor://code/read" => :auto,
        "arbor://fs/read" => :auto,
        "arbor://historian/query" => :auto,
        # Writes blocked (too risky for cautious users)
        "arbor://code/write" => :block,
        # Shell blocked
        "arbor://shell" => :block
      }
    }
  end

  def preset(:balanced) do
    %{
      baseline: :ask,
      rules: %{
        # Orchestrator required for all agents to function
        "arbor://orchestrator" => :auto,
        # Reads are frictionless
        "arbor://code/read" => :auto,
        "arbor://fs/read" => :auto,
        "arbor://historian/query" => :auto,
        # Writes are gated
        "arbor://code/write" => :ask,
        "arbor://fs/write" => :allow,
        # Shell gated for specific commands
        "arbor://shell/exec/git" => :ask
      }
    }
  end

  def preset(:hands_off) do
    %{
      baseline: :allow,
      rules: %{
        # Orchestrator required for all agents to function
        "arbor://orchestrator" => :auto,
        # Reads and writes are automatic
        "arbor://code/read" => :auto,
        "arbor://code/write" => :auto,
        # Shell and governance always gated
        "arbor://shell" => :ask,
        "arbor://governance" => :ask
      }
    }
  end

  def preset(:full_trust) do
    %{
      baseline: :auto,
      rules: %{
        # Orchestrator required for all agents to function
        "arbor://orchestrator" => :auto,
        # Shell and governance always gated (security ceiling)
        "arbor://shell" => :ask,
        "arbor://governance" => :ask
      }
    }
  end

  def preset(_unknown), do: preset(:balanced)

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
