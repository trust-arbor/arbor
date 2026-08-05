defmodule Arbor.Orchestrator.Session.TurnEgress do
  @moduledoc false

  # VP-05D2A1P5 — Session-owned frozen route, disclosure issue, turn-egress
  # authorizer, and initial-taint derivation. Process-local only; never enters
  # Engine JSON context or public Session state.

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.TurnAuthority

  @route_keys [:destination, :provider, :runtime, :model]
  @accepted_runtimes MapSet.new(["arbor", "acp"])
  # Session turn freeze admits only these two tiers. :on_premises, :none,
  # :external_peer, nil, and any other atom fail closed (never dark-gate open).
  @admitted_frozen_tiers MapSet.new([:on_host, :external_provider])
  @max_route_field_bytes 256
  @user_taint_keys ~w(session.input session.query session.messages session.user_media session.task_id)
  @taint_keys [
    :__struct__,
    :level,
    :sensitivity,
    :sanitizations,
    :confidence,
    :source,
    :chain
  ]

  @type scalar_route :: %{
          destination: String.t(),
          provider: String.t(),
          runtime: String.t(),
          model: String.t()
        }

  @type fence :: :atomics.atomics_ref()

  @doc false
  @spec new_fence() :: fence()
  def new_fence do
    ref = :atomics.new(1, [])
    :atomics.put(ref, 1, 1)
    ref
  end

  @doc false
  @spec deactivate_fence(fence() | nil) :: :ok
  def deactivate_fence(nil), do: :ok

  def deactivate_fence(ref) do
    :atomics.put(ref, 1, 0)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec fence_active?(fence() | nil) :: boolean()
  def fence_active?(nil), do: false

  def fence_active?(ref) do
    :atomics.get(ref, 1) == 1
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc false
  @spec graph_compute_mode(term()) :: :tool_loop | :non_tool | :ambiguous | :none
  def graph_compute_mode(%{nodes: nodes}) when is_map(nodes) do
    compute_nodes =
      nodes
      |> Map.values()
      |> Enum.filter(&compute_node?/1)

    tool_loop? = Enum.any?(compute_nodes, &tool_loop_node?/1)
    non_tool? = Enum.any?(compute_nodes, &(not tool_loop_node?(&1)))

    cond do
      compute_nodes == [] -> :none
      tool_loop? and non_tool? -> :ambiguous
      tool_loop? -> :tool_loop
      true -> :non_tool
    end
  end

  def graph_compute_mode(nil), do: :none
  def graph_compute_mode(_), do: :ambiguous

  defp compute_node?(%{attrs: attrs}) when is_map(attrs) do
    type = Map.get(attrs, "type") || Map.get(attrs, :type)
    type in ["compute", :compute]
  end

  defp compute_node?(_), do: false

  defp tool_loop_node?(%{attrs: attrs}) when is_map(attrs) do
    Map.get(attrs, "use_tools") in ["true", true]
  end

  defp tool_loop_node?(_), do: false

  @doc false
  @spec resolve_frozen_route(map(), term()) ::
          {:ok, %{route: scalar_route(), provider_route_input: map() | nil}}
          | {:error, atom()}
  def resolve_frozen_route(state, turn_graph) do
    case graph_compute_mode(turn_graph) do
      :tool_loop ->
        with {:ok, route} <- resolve_configured_route(state) do
          {:ok, %{route: route, provider_route_input: nil}}
        end

      :non_tool ->
        resolve_non_tool_route(state, turn_graph)

      :none ->
        # Transform-only / no-compute graphs (tests + non-LLM turns): prefer
        # configured route when present; otherwise a closed local sentinel so
        # prepare still installs fence+authorizer without inventing Application
        # routing state. Real provider attempts must still exact-match.
        case resolve_configured_route(state) do
          {:ok, route} ->
            {:ok, %{route: route, provider_route_input: nil}}

          {:error, _} ->
            {:ok, %{route: no_llm_sentinel_route(), provider_route_input: nil}}
        end

      :ambiguous ->
        {:error, :ambiguous_compute_route}
    end
  end

  defp no_llm_sentinel_route do
    %{
      destination: "lmstudio",
      provider: "lmstudio",
      runtime: "arbor",
      model: "session-no-llm"
    }
  end

  defp resolve_non_tool_route(state, turn_graph) do
    with {:ok, task_class} <- single_task_class(turn_graph) do
      case Arbor.AI.freeze_provider_route(task_class) do
        {:ok, %{provider_route_input: input, route: route}} ->
          case canonicalize_route(route) do
            {:ok, scalar} ->
              {:ok, %{route: scalar, provider_route_input: input}}

            {:error, _} ->
              {:error, :route_freeze_failed}
          end

        {:error, :disabled} ->
          # Disabled ProviderRouter may use the same bounded configured legacy
          # route rule; when config is absent (hermetic non-LLM computes), use
          # the closed local sentinel rather than inventing Application routing.
          case resolve_configured_route(state) do
            {:ok, route} ->
              {:ok, %{route: route, provider_route_input: nil}}

            {:error, _} ->
              {:ok, %{route: no_llm_sentinel_route(), provider_route_input: nil}}
          end

        {:error, {:route_assembly_failed, _}} ->
          {:error, :route_assembly_failed}

        {:error, :route_freeze_failed} ->
          {:error, :route_freeze_failed}

        _ ->
          {:error, :route_freeze_failed}
      end
    end
  end

  defp single_task_class(%{nodes: nodes}) when is_map(nodes) do
    classes =
      nodes
      |> Map.values()
      |> Enum.filter(&(compute_node?(&1) and not tool_loop_node?(&1)))
      |> Enum.map(fn node ->
        attrs = node.attrs || %{}
        Map.get(attrs, "task_class") || Map.get(attrs, :task_class)
      end)
      |> Enum.uniq()

    case classes do
      [] -> {:ok, nil}
      [nil] -> {:ok, nil}
      [class] when is_binary(class) -> {:ok, class}
      [_single] -> {:error, :invalid_task_class}
      _many -> {:error, :ambiguous_task_class}
    end
  end

  defp single_task_class(_), do: {:error, :ambiguous_task_class}

  @doc false
  @spec resolve_configured_route(map()) :: {:ok, scalar_route()} | {:error, atom()}
  def resolve_configured_route(state) do
    config = Map.get(state, :config) || %{}
    provider = config["llm_provider"] || config[:llm_provider]
    model = config["llm_model"] || config[:llm_model]

    with {:ok, provider_bin} <- canonical_field(provider),
         {:ok, model_bin} <- canonical_field(model) do
      canonicalize_route(%{
        destination: provider_bin,
        provider: provider_bin,
        runtime: "arbor",
        model: model_bin
      })
    else
      _ -> {:error, :missing_configured_route}
    end
  end

  @doc false
  @spec canonicalize_route(term()) :: {:ok, scalar_route()} | {:error, atom()}
  def canonicalize_route(route) when is_map(route) do
    keys = route |> Map.keys() |> Enum.sort()
    expected = Enum.sort(@route_keys)

    if keys != expected do
      {:error, :invalid_route}
    else
      with {:ok, destination} <- canonical_field(Map.get(route, :destination)),
           {:ok, provider} <- canonical_field(Map.get(route, :provider)),
           {:ok, runtime} <- canonical_runtime(Map.get(route, :runtime)),
           {:ok, model} <- canonical_field(Map.get(route, :model)) do
        {:ok,
         %{
           destination: destination,
           provider: provider,
           runtime: runtime,
           model: model
         }}
      else
        _ -> {:error, :invalid_route}
      end
    end
  end

  def canonicalize_route(_), do: {:error, :invalid_route}

  defp canonical_field(value) when is_atom(value) and value not in [nil, true, false] do
    canonical_field(Atom.to_string(value))
  end

  defp canonical_field(value) when is_binary(value) do
    cond do
      value == "" ->
        {:error, :invalid_route_field}

      not String.valid?(value) ->
        {:error, :invalid_route_field}

      String.trim(value) != value ->
        {:error, :invalid_route_field}

      String.match?(value, ~r/[\x00-\x1F\x7F]/) ->
        {:error, :invalid_route_field}

      byte_size(value) > @max_route_field_bytes ->
        {:error, :invalid_route_field}

      true ->
        {:ok, value}
    end
  end

  defp canonical_field(_), do: {:error, :invalid_route_field}

  defp canonical_runtime(value) when is_atom(value) and value not in [nil, true, false] do
    canonical_runtime(Atom.to_string(value))
  end

  defp canonical_runtime(value) when is_binary(value) do
    with {:ok, runtime} <- canonical_field(value) do
      if MapSet.member?(@accepted_runtimes, runtime) do
        {:ok, runtime}
      else
        {:error, :invalid_runtime}
      end
    end
  end

  defp canonical_runtime(_), do: {:error, :invalid_runtime}

  @doc false
  @spec project_request_route(term()) :: {:ok, scalar_route()} | {:error, atom()}
  def project_request_route(%{provider: provider, model: model} = req) do
    runtime =
      case Map.get(req, :runtime) do
        nil -> "arbor"
        :arbor -> "arbor"
        :acp -> "acp"
        other -> other
      end

    provider_bin =
      case provider do
        p when is_atom(p) and p not in [nil, true, false] -> Atom.to_string(p)
        p when is_binary(p) -> p
        _ -> nil
      end

    canonicalize_route(%{
      destination: provider_bin,
      provider: provider_bin,
      runtime: runtime,
      model: model
    })
  end

  def project_request_route(_), do: {:error, :invalid_route}

  @doc false
  @spec project_dispatch_route(term()) :: {:ok, scalar_route()} | {:error, atom()}
  def project_dispatch_route(route) when is_map(route) do
    # Prefer already-scalar four-key maps; otherwise project P1 rich routes.
    case canonicalize_route(route) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        bound_dest = bound_dispatch_destination(route)
        provider = dispatch_provider_identity(route, bound_dest)

        # Prefer P1-bound destination; non-legacy routes without an explicit
        # destination may fall back to the projected catalog provider string.
        # :legacy never falls back to the atom name \"legacy\".
        destination =
          case bound_dest do
            d when is_binary(d) -> d
            _ when is_binary(provider) -> provider
            _ -> nil
          end

        runtime =
          case Map.get(route, :runtime) do
            r when is_atom(r) and r not in [nil, true, false] -> Atom.to_string(r)
            r when is_binary(r) -> r
            _ -> nil
          end

        model = Map.get(route, :model)

        canonicalize_route(%{
          destination: destination,
          provider: provider,
          runtime: runtime,
          model: model
        })
    end
  end

  def project_dispatch_route(_), do: {:error, :invalid_route}

  # Bound wire destination after P1 destination binding. Missing destination is
  # not inventable from a synthesized catalog id.
  defp bound_dispatch_destination(route) do
    case Map.get(route, :destination) do
      d when is_binary(d) and d != "" -> d
      _ -> nil
    end
  end

  # Source-owned provider identity for authorization equality against the Session
  # frozen scalar. Catalog ProviderEntry ids project via Atom.to_string/1, except
  # the synthesized `:legacy` entry used for uncatalogued models: its catalog id
  # is not a real outbound provider, so use the already-bound destination (the
  # actual request provider string) — matching Router-disabled configured freeze
  # which sets provider = destination = configured outbound provider.
  defp dispatch_provider_identity(route, destination) do
    case Map.get(route, :provider) do
      %{id: :legacy} ->
        destination

      :legacy ->
        destination

      %{id: id} when is_atom(id) and id not in [nil, true, false, :legacy] ->
        Atom.to_string(id)

      id when is_atom(id) and id not in [nil, true, false, :legacy] ->
        Atom.to_string(id)

      id when is_binary(id) ->
        id

      _ ->
        nil
    end
  end

  @doc false
  @spec derive_initial_taint(map(), map()) :: %{String.t() => :untrusted}
  def derive_initial_taint(pre_values, final_values)
      when is_map(pre_values) and is_map(final_values) do
    base_keys =
      @user_taint_keys
      |> Enum.filter(&Map.has_key?(final_values, &1))

    changed_keys =
      final_values
      |> Map.keys()
      |> Enum.filter(fn key ->
        not Map.has_key?(pre_values, key) or
          Map.get(pre_values, key) != Map.get(final_values, key)
      end)

    media_config_keys =
      if Map.has_key?(final_values, "session.user_media") and
           Map.has_key?(final_values, "session.config") and
           config_carries_same_media?(
             Map.get(final_values, "session.config"),
             Map.get(final_values, "session.user_media")
           ) do
        ["session.config"]
      else
        []
      end

    (base_keys ++ changed_keys ++ media_config_keys)
    |> Enum.uniq()
    |> Map.new(fn key -> {key, :untrusted} end)
  end

  def derive_initial_taint(_pre, final_values) when is_map(final_values) do
    derive_initial_taint(%{}, final_values)
  end

  def derive_initial_taint(_, _), do: %{}

  defp config_carries_same_media?(config, media) when is_map(config) do
    cfg_media = Map.get(config, "user_media") || Map.get(config, :user_media)
    not is_nil(cfg_media) and cfg_media == media
  end

  defp config_carries_same_media?(_, _), do: false

  @doc false
  @spec admit_frozen_tier(term()) :: {:ok, :on_host | :external_provider} | {:error, atom()}
  def admit_frozen_tier(tier) when is_atom(tier) do
    if MapSet.member?(@admitted_frozen_tiers, tier) do
      {:ok, tier}
    else
      {:error, :invalid_frozen_tier}
    end
  end

  def admit_frozen_tier(_), do: {:error, :invalid_frozen_tier}

  @doc false
  @spec issue_disclosure_if_needed(
          map(),
          TurnAuthority.t() | nil,
          scalar_route(),
          atom()
        ) ::
          {:ok, TurnAuthority.t() | nil, String.t() | nil}
          | {:error, atom()}
  def issue_disclosure_if_needed(_state, nil, _route, frozen_tier)
      when frozen_tier in [:on_host, :external_provider],
      do: {:ok, nil, nil}

  def issue_disclosure_if_needed(state, %TurnAuthority{} = authority, route, :external_provider) do
    opts = [
      principal_id: state.agent_id,
      session_id: state.session_id,
      task_id: authority.turn_id,
      principal_scope: authority.authenticated_principal_id,
      destination: route.destination,
      provider: route.provider,
      runtime: route.runtime,
      model: route.model
    ]

    case Arbor.Security.issue_disclosure_capability(opts) do
      {:ok, cap} ->
        case TurnAuthority.new(
               turn_id: authority.turn_id,
               authenticated_principal_id: authority.authenticated_principal_id,
               disclosure_capability_id: cap.id
             ) do
          {:ok, bound} ->
            {:ok, bound, cap.id}

          {:error, _} ->
            _ = safe_revoke_disclosure(cap.id)
            {:error, :disclosure_bind_failed}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :disclosure_issue_failed}
    end
  rescue
    _ -> {:error, :disclosure_issue_failed}
  catch
    _, _ -> {:error, :disclosure_issue_failed}
  end

  def issue_disclosure_if_needed(_state, %TurnAuthority{} = authority, _route, :on_host),
    do: {:ok, authority, nil}

  def issue_disclosure_if_needed(_state, _authority, _route, frozen_tier)
      when not is_atom(frozen_tier) or frozen_tier not in [:on_host, :external_provider],
      do: {:error, :invalid_frozen_tier}

  def issue_disclosure_if_needed(_state, _authority, _route, _frozen_tier),
    do: {:error, :invalid_authority}

  @doc false
  @spec safe_revoke_disclosure(String.t() | nil) :: :ok
  def safe_revoke_disclosure(nil), do: :ok

  def safe_revoke_disclosure(cap_id) when is_binary(cap_id) do
    _ = Arbor.Security.revoke(cap_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def safe_revoke_disclosure(_), do: :ok

  @doc false
  @spec build_authorizer(map()) :: (term() -> :allow | {:error, term()})
  def build_authorizer(bindings) when is_map(bindings) do
    taint_authorizer = build_taint_authorizer(bindings)
    conservative_taint = %Taint{level: :untrusted, sensitivity: :internal}

    fn route -> taint_authorizer.(route, conservative_taint) end
  end

  @doc false
  @spec build_taint_authorizer(map()) ::
          (term(), Taint.t() -> :allow | {:error, term()})
  def build_taint_authorizer(bindings) when is_map(bindings) do
    fence = Map.fetch!(bindings, :fence)
    frozen = Map.fetch!(bindings, :frozen_route)
    frozen_tier = Map.fetch!(bindings, :frozen_tier)
    agent_id = Map.fetch!(bindings, :agent_id)
    session_id = Map.fetch!(bindings, :session_id)
    turn_id = Map.get(bindings, :turn_id)
    human_id = Map.get(bindings, :human_id)
    disclosure_id = Map.get(bindings, :disclosure_capability_id)

    fn route, taint ->
      case validated_taint_level(taint) do
        {:ok, taint_level} ->
          authorize_turn_egress(
            route,
            taint_level,
            fence,
            frozen,
            frozen_tier,
            agent_id,
            session_id,
            turn_id,
            human_id,
            disclosure_id
          )

        :error ->
          {:error, {:egress_blocked, :external_provider, :invalid_taint}}
      end
    end
  end

  defp validated_taint_level(%Taint{} = taint) do
    if map_size(taint) == length(@taint_keys) and
         Enum.sort(Map.keys(taint)) == Enum.sort(@taint_keys) and
         taint.level in Taint.levels() and
         taint.sensitivity in Taint.sensitivities() and
         taint.confidence in Taint.confidences() and
         is_integer(taint.sanitizations) and taint.sanitizations in 0..255 and
         valid_taint_source?(taint.source) and valid_taint_chain?(taint.chain) do
      {:ok, taint.level}
    else
      :error
    end
  end

  defp validated_taint_level(_taint), do: :error

  defp valid_taint_source?(nil), do: true
  defp valid_taint_source?(source), do: is_binary(source) and String.valid?(source)

  defp valid_taint_chain?(chain) when is_list(chain) do
    Enum.all?(chain, &(is_binary(&1) and String.valid?(&1)))
  end

  defp valid_taint_chain?(_chain), do: false

  defp authorize_turn_egress(
         route,
         taint_level,
         fence,
         frozen,
         frozen_tier,
         agent_id,
         session_id,
         turn_id,
         human_id,
         disclosure_id
       ) do
    cond do
      not fence_active?(fence) ->
        {:error, {:egress_blocked, :external_provider, :fence_inactive}}

      not MapSet.member?(@admitted_frozen_tiers, frozen_tier) ->
        # Unknown/nil/on_premises/external_peer/etc. never dark-gate open.
        {:error, {:egress_blocked, :external_provider, :invalid_frozen_tier}}

      true ->
        case canonicalize_route(route) do
          {:ok, scalar} ->
            if scalar == frozen do
              trust_authorize(
                agent_id,
                scalar,
                frozen_tier,
                taint_level,
                session_id,
                turn_id,
                human_id,
                disclosure_id
              )
            else
              {:error, {:egress_blocked, :external_provider, :route_mismatch}}
            end

          {:error, _} ->
            {:error, {:egress_blocked, :external_provider, :invalid_route}}
        end
    end
  rescue
    _ -> {:error, {:egress_blocked, :external_provider, :authorizer_fault}}
  catch
    _, _ -> {:error, {:egress_blocked, :external_provider, :authorizer_fault}}
  end

  # Uses the prepare-time frozen tier only — never reclassifies via
  # Arbor.AI.egress_tier_for/1 on the attempt path.
  defp trust_authorize(
         agent_id,
         route,
         frozen_tier,
         taint_level,
         session_id,
         turn_id,
         human_id,
         disclosure_id
       ) do
    if frozen_tier == :external_provider and not valid_disclosure_id?(disclosure_id) do
      # Session-owned external deny even when EgressGate is dark.
      {:error, {:egress_blocked, :external_provider, :disclosure_required}}
    else
      opts =
        [
          egress_taint: taint_level,
          egress_destination: route.destination,
          egress_provider: route.provider,
          egress_runtime: route.runtime,
          egress_model: route.model,
          session_id: session_id
        ]
        |> maybe_put(:task_id, turn_id)
        |> maybe_put(:principal_scope, human_id)
        |> maybe_put(:disclosure_capability_id, disclosure_id)

      case Arbor.Trust.authorize_egress(agent_id, frozen_tier, opts) do
        :allow ->
          finalize_external_allow(
            frozen_tier,
            agent_id,
            disclosure_id,
            session_id,
            turn_id,
            human_id,
            route
          )

        {:requires_approval, _} ->
          {:error, {:egress_blocked, frozen_tier, :pending}}

        {:error, _} = err ->
          err

        _ ->
          {:error, {:egress_blocked, frozen_tier, :unknown}}
      end
    end
  rescue
    _ -> {:error, {:egress_blocked, :external_provider, :trust_unavailable}}
  catch
    _, _ -> {:error, {:egress_blocked, :external_provider, :trust_unavailable}}
  end

  # After ordinary Trust :allow, external routes still require exact public
  # Security revalidation — independent of :egress_gate_enforcing.
  defp finalize_external_allow(
         :external_provider,
         agent_id,
         disclosure_id,
         session_id,
         turn_id,
         human_id,
         route
       ) do
    if not valid_disclosure_id?(disclosure_id) do
      {:error, {:egress_blocked, :external_provider, :disclosure_required}}
    else
      validate_opts =
        [
          session_id: session_id,
          task_id: turn_id,
          principal_scope: human_id,
          egress_destination: route.destination,
          egress_provider: route.provider,
          egress_runtime: route.runtime,
          egress_model: route.model
        ]

      case Arbor.Security.validate_disclosure_capability(
             agent_id,
             disclosure_id,
             validate_opts
           ) do
        :ok ->
          :allow

        {:error, _} ->
          {:error, {:egress_blocked, :external_provider, :disclosure_rejected}}

        _ ->
          {:error, {:egress_blocked, :external_provider, :disclosure_rejected}}
      end
    end
  rescue
    _ -> {:error, {:egress_blocked, :external_provider, :disclosure_unavailable}}
  catch
    _, _ -> {:error, {:egress_blocked, :external_provider, :disclosure_unavailable}}
  end

  # Local host routes use ordinary Trust semantics only — no disclosure.
  defp finalize_external_allow(:on_host, _agent, _cap, _session, _turn, _human, _route),
    do: :allow

  # Any other tier must never open under a dark EgressGate.
  defp finalize_external_allow(_other, _agent, _cap, _session, _turn, _human, _route),
    do: {:error, {:egress_blocked, :external_provider, :invalid_frozen_tier}}

  defp valid_disclosure_id?(id) when is_binary(id) do
    Regex.match?(~r/^cap_[0-9a-f]{32}$/, id)
  end

  defp valid_disclosure_id?(_), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc false
  @spec disclosure_id_from_authority(TurnAuthority.t() | nil) :: String.t() | nil
  def disclosure_id_from_authority(%TurnAuthority{disclosure_capability_id: id})
      when is_binary(id),
      do: id

  def disclosure_id_from_authority(_), do: nil
end
