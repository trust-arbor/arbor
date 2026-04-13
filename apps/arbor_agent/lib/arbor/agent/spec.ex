defmodule Arbor.Agent.Spec do
  @moduledoc """
  Pure CRC module for constructing fully-resolved agent specifications.

  All agent creation paths converge here. No side effects — takes configuration
  inputs and produces a complete `%Arbor.Contracts.Agent.Spec{}` with all
  ambiguities resolved (template, trust tier, model, tools).

  ## Construct

      spec = Spec.new(
        display_name: "diagnostician",
        template: "diagnostician",
        model_config: %{id: "arcee-ai/trinity-large-preview:free", provider: :openrouter}
      )

  ## Convert

      profile = Spec.to_profile(spec, agent_id, identity)
      session_opts = Spec.to_session_opts(spec, agent_id, signer)
  """

  alias Arbor.Contracts.Agent.Spec, as: AgentSpec
  alias Arbor.Agent.{Character, Profile}

  require Logger

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Build a fully-resolved agent specification from options.

  Resolves template (if provided), merges model config, determines trust tier,
  and validates all required fields. Returns `{:ok, spec}` or `{:error, reason}`.

  ## Options

  - `:display_name` — required, human-readable name
  - `:template` — template name (string) or module (atom)
  - `:model_config` — map with provider/model info (`%{id: "model", provider: :openrouter}`)
  - `:trust_tier` — explicit trust tier (overrides template)
  - `:character` — explicit Character struct (overrides template)
  - `:initial_goals` — list of goal maps
  - `:capabilities` — list of initial capability maps
  - `:system_prompt` — explicit system prompt (overrides template)
  - `:auto_start` — whether to start on boot
  - `:delegator_id` — parent agent for delegation
  - `:tenant_context` — multi-user context
  """
  @spec new(keyword()) :: {:ok, AgentSpec.t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    display_name = Keyword.get(opts, :display_name)

    unless display_name do
      {:error, :missing_display_name}
    else
      spec =
        %AgentSpec{display_name: display_name}
        |> apply_template(opts)
        |> apply_model_config(opts)
        |> apply_trust_tier(opts)
        |> apply_explicit_overrides(opts)
        |> apply_metadata(opts)

      {:ok, spec}
    end
  end

  @doc """
  Reconstruct a spec from a persisted Profile + model_config.

  Used for resume path — the Profile has the resolved values, so we
  don't need to re-resolve the template.
  """
  @spec from_profile(Profile.t(), map()) :: {:ok, AgentSpec.t()}
  def from_profile(%Profile{} = profile, model_config \\ %{}) do
    provider =
      model_config["llm_provider"] || model_config[:llm_provider] ||
        model_config[:provider] || model_config["provider"]

    model =
      model_config["llm_model"] || model_config[:llm_model] ||
        model_config[:id] || model_config["id"]

    spec = %AgentSpec{
      display_name: profile.display_name,
      character: profile.character,
      trust_tier: profile.trust_tier || :untrusted,
      template: profile.template,
      provider: safe_to_atom(provider),
      model: model,
      system_prompt: model_config["system_prompt"],
      initial_goals: profile.initial_goals || [],
      initial_capabilities: profile.initial_capabilities || [],
      auto_start: profile.auto_start || false,
      model_config: model_config,
      metadata: profile.metadata || %{}
    }

    {:ok, spec}
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc """
  Convert a spec to a Profile struct for persistence.

  Requires `agent_id` and `identity` (from crypto key generation).
  """
  @spec to_profile(AgentSpec.t(), String.t(), map()) :: Profile.t()
  def to_profile(%AgentSpec{} = spec, agent_id, identity) do
    template =
      case spec.template do
        mod when is_atom(mod) and not is_nil(mod) ->
          template_store = Module.concat([:Arbor, :Agent, :TemplateStore])

          if Code.ensure_loaded?(template_store) and
               function_exported?(template_store, :module_to_name, 1) do
            apply(template_store, :module_to_name, [mod])
          else
            to_string(mod)
          end

        other ->
          other
      end

    public_key =
      case identity do
        %{public_key: pk} when is_binary(pk) -> Base.encode16(pk, case: :lower)
        _ -> nil
      end

    endorsement = Map.get(identity, :endorsement)

    %Profile{
      agent_id: agent_id,
      display_name: spec.display_name,
      character: spec.character,
      trust_tier: spec.trust_tier,
      template: template,
      initial_goals: spec.initial_goals,
      initial_capabilities: spec.initial_capabilities,
      identity: %{
        agent_id: agent_id,
        public_key: public_key,
        endorsement: endorsement
      },
      auto_start: spec.auto_start,
      metadata:
        Map.merge(spec.metadata, %{
          last_model_config: spec.model_config
        }),
      created_at: DateTime.utc_now(),
      version: 1
    }
  end

  @doc """
  Convert a spec to Session init options.
  """
  @spec to_session_opts(AgentSpec.t(), String.t(), keyword()) :: keyword()
  def to_session_opts(%AgentSpec{} = spec, agent_id, extra_opts \\ []) do
    config =
      %{}
      |> maybe_put("llm_provider", if(spec.provider, do: to_string(spec.provider)))
      |> maybe_put("llm_model", spec.model)
      |> maybe_put("system_prompt", spec.system_prompt)

    [
      session_id: "agent-session-#{agent_id}",
      agent_id: agent_id,
      trust_tier: spec.trust_tier,
      config: config,
      execution_mode: spec.execution_mode
    ] ++ extra_opts
  end

  @doc """
  Convert a spec to Lifecycle.create opts (migration bridge).

  During the migration period, this allows existing code to call
  Lifecycle.create with opts derived from the spec.
  """
  @spec to_lifecycle_opts(AgentSpec.t()) :: keyword()
  def to_lifecycle_opts(%AgentSpec{} = spec) do
    opts = [
      trust_tier: spec.trust_tier,
      initial_goals: spec.initial_goals,
      capabilities: spec.initial_capabilities
    ]

    opts = if spec.template, do: Keyword.put(opts, :template, spec.template), else: opts
    opts = if spec.character, do: Keyword.put(opts, :character, spec.character), else: opts

    opts =
      if spec.delegator_id, do: Keyword.put(opts, :delegator_id, spec.delegator_id), else: opts

    opts =
      if spec.tenant_context,
        do: Keyword.put(opts, :tenant_context, spec.tenant_context),
        else: opts

    opts
  end

  # ===========================================================================
  # Private — Pure Resolution Functions
  # ===========================================================================

  # Apply template if provided. Resolves character, trust_tier, goals, caps from template.
  defp apply_template(spec, opts) do
    case Keyword.get(opts, :template) do
      nil ->
        # No template — use explicit character if provided
        case Keyword.get(opts, :character) do
          %Character{} = char -> %{spec | character: char}
          _ -> spec
        end

      template_name when is_binary(template_name) ->
        resolve_template_by_name(spec, template_name, opts)

      template_mod when is_atom(template_mod) ->
        resolve_template_by_module(spec, template_mod, opts)
    end
  end

  defp resolve_template_by_name(spec, name, _opts) do
    template_store = Module.concat([:Arbor, :Agent, :TemplateStore])

    if Code.ensure_loaded?(template_store) and
         function_exported?(template_store, :resolve, 1) do
      case apply(template_store, :resolve, [name]) do
        {:ok, data} ->
          kw = apply(template_store, :to_keyword, [data])
          apply_template_data(spec, name, kw)

        {:error, _} ->
          # Try as module name
          try_module_template(spec, name)
      end
    else
      try_module_template(spec, name)
    end
  end

  defp resolve_template_by_module(spec, mod, _opts) do
    template_store = Module.concat([:Arbor, :Agent, :TemplateStore])

    # Try store first, fall back to direct module
    resolved =
      if Code.ensure_loaded?(template_store) and function_exported?(template_store, :resolve, 1) do
        case apply(template_store, :resolve, [mod]) do
          {:ok, data} ->
            name = apply(template_store, :module_to_name, [mod])
            kw = apply(template_store, :to_keyword, [data])
            {:ok, name, kw}

          {:error, _} ->
            :fallback
        end
      else
        :fallback
      end

    case resolved do
      {:ok, name, kw} ->
        spec = apply_template_data(spec, name, kw)
        %{spec | template_module: mod}

      :fallback ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :character, 0) do
          character = mod.character()

          trust_tier =
            if function_exported?(mod, :trust_tier, 0), do: mod.trust_tier(), else: nil

          goals =
            if function_exported?(mod, :initial_goals, 0), do: mod.initial_goals(), else: []

          caps =
            if function_exported?(mod, :required_capabilities, 0),
              do: mod.required_capabilities(),
              else: []

          %{
            spec
            | character: character,
              trust_tier: trust_tier || spec.trust_tier,
              template: mod,
              template_module: mod,
              initial_goals: goals,
              initial_capabilities: caps
          }
        else
          spec
        end
    end
  end

  defp try_module_template(spec, name) do
    # Try to resolve "diagnostician" → Arbor.Agent.Templates.Diagnostician
    module_name =
      name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")

    mod = Module.concat([Arbor, Agent, Templates, module_name])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :character, 0) do
      resolve_template_by_module(spec, mod, [])
    else
      %{spec | template: name}
    end
  end

  defp apply_template_data(spec, name, kw) do
    %{
      spec
      | character: kw[:character] || spec.character,
        trust_tier: kw[:trust_tier] || spec.trust_tier,
        template: name,
        initial_goals: kw[:initial_goals] || spec.initial_goals,
        initial_capabilities: kw[:required_capabilities] || spec.initial_capabilities
    }
  end

  # Apply model config from opts
  defp apply_model_config(spec, opts) do
    model_config = Keyword.get(opts, :model_config, %{})

    provider =
      model_config[:provider] || model_config["provider"] ||
        model_config[:llm_provider] || model_config["llm_provider"]

    model =
      model_config[:id] || model_config["id"] ||
        model_config[:llm_model] || model_config["llm_model"]

    system_prompt = model_config[:system_prompt] || model_config["system_prompt"]

    %{
      spec
      | provider: safe_to_atom(provider) || spec.provider,
        model: model || spec.model,
        system_prompt: system_prompt || spec.system_prompt,
        model_config: model_config
    }
  end

  # Apply trust tier — explicit opts override template
  defp apply_trust_tier(spec, opts) do
    case Keyword.get(opts, :trust_tier) do
      nil -> spec
      tier -> %{spec | trust_tier: tier}
    end
  end

  # Apply any explicit overrides from opts
  defp apply_explicit_overrides(spec, opts) do
    spec
    |> maybe_override(:character, Keyword.get(opts, :character))
    |> maybe_override(:initial_goals, Keyword.get(opts, :initial_goals))
    |> maybe_override(:initial_capabilities, Keyword.get(opts, :capabilities))
    |> maybe_override(:system_prompt, Keyword.get(opts, :system_prompt))
    |> maybe_override(:auto_start, Keyword.get(opts, :auto_start))
    |> maybe_override(:delegator_id, Keyword.get(opts, :delegator_id))
    |> maybe_override(:tenant_context, Keyword.get(opts, :tenant_context))
    |> maybe_override(:execution_mode, Keyword.get(opts, :execution_mode))
  end

  defp apply_metadata(spec, opts) do
    extra = Keyword.get(opts, :metadata, %{})
    %{spec | metadata: Map.merge(spec.metadata, extra)}
  end

  # Only override if value is non-nil
  defp maybe_override(spec, _field, nil), do: spec
  defp maybe_override(spec, field, value), do: Map.put(spec, field, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(a) when is_atom(a), do: a

  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> String.to_atom(s)
    end
  end
end
