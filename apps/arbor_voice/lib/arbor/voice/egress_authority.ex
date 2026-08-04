defmodule Arbor.Voice.EgressAuthority do
  @moduledoc false

  alias Arbor.Voice.Redacted

  @xai_route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }
  @route_keys MapSet.new([:destination, :provider, :runtime, :model])
  @route_resource_prefix "arbor://voice/realtime/xai"
  @route_cleanup_key :voice_realtime_route_capability
  @route_expiry_grace_seconds 60
  @max_route_lifetime_seconds 86_460
  @authorization_error :voice_effect_not_authorized
  @lower_hex_32 ~r/\A[0-9a-f]{32}\z/

  @route_effects [:connect, :configure]
  @turn_effects [
    :text_item,
    :text_response,
    :audio_append,
    :audio_commit,
    :audio_response,
    :tool_result_item,
    :tool_result_response
  ]
  @effects @route_effects ++ @turn_effects

  @type route :: Arbor.Voice.RealtimeBackend.egress_route()
  @type session_authority :: map()
  @type turn_authority :: map()

  @spec resolve_backend_route(module(), module()) ::
          {:ok, %{kind: :local, route: :none}}
          | {:ok, %{kind: :external, route: map(), tier: :external_provider}}
          | {:error, :start_failed}
  def resolve_backend_route(backend, ai_module)
      when is_atom(backend) and is_atom(ai_module) do
    case safe_backend_route(backend) do
      :none ->
        {:ok, %{kind: :local, route: :none}}

      route when is_map(route) ->
        with true <- canonical_route_shape?(route),
             true <- route == @xai_route,
             :external_provider <- safe_classify(ai_module, route) do
          {:ok, %{kind: :external, route: route, tier: :external_provider}}
        else
          _ -> {:error, :start_failed}
        end

      _ ->
        {:error, :start_failed}
    end
  end

  def resolve_backend_route(_backend, _ai_module), do: {:error, :start_failed}

  @spec authenticate_human(map(), map()) :: :ok | {:error, :start_failed}
  def authenticate_human(%{kind: :local}, _config), do: :ok

  def authenticate_human(%{kind: :external}, config) when is_map(config) do
    security = Map.get(config, :security_module)
    user_id = Map.get(config, :user_id)
    agent_id = Map.get(config, :agent_id)
    resource = chat_resource(agent_id)

    with %Redacted{} = token <- Map.get(config, :session_token),
         {:ok, receipt} <-
           safe_apply(security, :authorize_and_issue_delivery_receipt, [
             user_id,
             resource,
             :chat,
             [session_token: Redacted.value(token)]
           ]),
         {:ok, ^user_id} <-
           safe_apply(security, :consume_delivery_receipt, [receipt, resource, :chat]) do
      :ok
    else
      _ -> {:error, :start_failed}
    end
  end

  def authenticate_human(_route_context, _config), do: {:error, :start_failed}

  @spec prepare_session_authority(map(), map(), String.t(), pos_integer()) ::
          {:ok, session_authority()} | {:error, :start_failed}
  def prepare_session_authority(
        %{kind: :local, route: :none},
        _config,
        session_id,
        _reserved_ms
      ) do
    if canonical_session_id?(session_id) do
      {:ok, %{kind: :local, route: :none, session_id: session_id}}
    else
      {:error, :start_failed}
    end
  end

  def prepare_session_authority(
        %{kind: :external, route: route, tier: :external_provider},
        config,
        session_id,
        reserved_ms
      )
      when is_map(config) and is_integer(reserved_ms) and reserved_ms > 0 do
    security = Map.get(config, :security_module)
    resource_uri = session_resource(session_id)

    with true <- is_binary(resource_uri),
         true <- safe_apply(security, :uri_registered?, [resource_uri]),
         {:ok, expires_at} <- route_expiry(Map.get(config, :wall_clock), reserved_ms),
         {:ok, capability_id} <-
           safe_apply(security, :grant_capability_id, [
             [
               principal: config.agent_id,
               resource: resource_uri,
               expires_at: expires_at,
               delegation_depth: 0,
               session_id: session_id,
               task_id: nil,
               principal_scope: config.user_id,
               constraints: %{
                 egress: %{
                   max_tier: :external_provider,
                   destinations: [route.destination]
                 }
               }
             ]
           ]),
         {:ok, capability_id} <- admit_capability_id(capability_id) do
      {:ok,
       %{
         kind: :external,
         route: route,
         tier: :external_provider,
         agent_id: config.agent_id,
         human_id: config.user_id,
         session_id: session_id,
         resource_uri: resource_uri,
         route_capability_id: capability_id,
         security_module: security,
         trust_module: config.trust_module
       }}
    else
      {:invalid_capability_id, id} ->
        _ = revoke_capability(security, id)
        {:error, :start_failed}

      _ ->
        {:error, :start_failed}
    end
  end

  def prepare_session_authority(_route_context, _config, _session_id, _reserved_ms),
    do: {:error, :start_failed}

  @spec owner_handoff(session_authority()) :: map()
  def owner_handoff(%{kind: :local} = authority) do
    %{authority: authority, initial_cleanup: nil}
  end

  def owner_handoff(%{kind: :external} = authority) do
    %{
      authority: authority,
      initial_cleanup: {@route_cleanup_key, capability_cleanup(authority)}
    }
  end

  @spec route_cleanup(session_authority()) :: (-> :ok | {:error, atom()})
  def route_cleanup(%{kind: :local}), do: fn -> :ok end
  def route_cleanup(%{kind: :external} = authority), do: capability_cleanup(authority)

  @spec issue_turn(session_authority(), String.t()) ::
          {:ok, turn_authority()} | {:error, :turn_failed}
  def issue_turn(%{kind: :local}, turn_id) when is_binary(turn_id) do
    {:ok, %{kind: :local, turn_id: turn_id, cleanup_key: {:voice_turn, turn_id}}}
  end

  def issue_turn(%{kind: :external} = authority, turn_id) when is_binary(turn_id) do
    route = authority.route

    issue_opts = [
      principal_id: authority.agent_id,
      session_id: authority.session_id,
      task_id: turn_id,
      principal_scope: authority.human_id,
      destination: route.destination,
      provider: route.provider,
      runtime: route.runtime,
      model: route.model
    ]

    case safe_apply(authority.security_module, :issue_disclosure_capability_id, [issue_opts]) do
      {:ok, capability_id} when is_binary(capability_id) ->
        case canonical_capability_id?(capability_id) do
          true ->
            cleanup_key = {:voice_turn, turn_id}

            {:ok,
             %{
               kind: :external,
               turn_id: turn_id,
               disclosure_capability_id: capability_id,
               cleanup_key: cleanup_key,
               cleanup: capability_cleanup(authority.security_module, capability_id)
             }}

          false ->
            _ = revoke_capability(authority.security_module, capability_id)
            {:error, :turn_failed}
        end

      _ ->
        {:error, :turn_failed}
    end
  end

  def issue_turn(_authority, _turn_id), do: {:error, :turn_failed}

  @spec turn_cleanup(turn_authority()) :: nil | (-> :ok | {:error, atom()})
  def turn_cleanup(%{kind: :local}), do: nil
  def turn_cleanup(%{kind: :external, cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup
  def turn_cleanup(_), do: nil

  @spec turn_cleanup_key(turn_authority()) :: term()
  def turn_cleanup_key(%{cleanup_key: key}), do: key

  @spec turn_lease(turn_authority()) :: map()
  def turn_lease(%{kind: :local, turn_id: turn_id, cleanup_key: cleanup_key}) do
    %{kind: :local, turn_id: turn_id, cleanup_key: cleanup_key}
  end

  def turn_lease(%{
        kind: :external,
        turn_id: turn_id,
        disclosure_capability_id: capability_id,
        cleanup_key: cleanup_key
      }) do
    %{
      kind: :external,
      turn_id: turn_id,
      disclosure_capability_id: capability_id,
      cleanup_key: cleanup_key
    }
  end

  @spec run_cleanup(nil | (-> term())) :: :ok | {:error, :cleanup_failed}
  def run_cleanup(nil), do: :ok

  def run_cleanup(cleanup) when is_function(cleanup, 0) do
    case cleanup.() do
      :ok -> :ok
      _ -> {:error, :cleanup_failed}
    end
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  def run_cleanup(_), do: {:error, :cleanup_failed}

  @doc false
  @spec canonical_session_id?(term()) :: boolean()
  def canonical_session_id?("session_" <> suffix),
    do: byte_size(suffix) == 32 and Regex.match?(@lower_hex_32, suffix)

  def canonical_session_id?(_), do: false

  @doc false
  @spec canonical_capability_id?(term()) :: boolean()
  def canonical_capability_id?("cap_" <> suffix),
    do: byte_size(suffix) == 32 and Regex.match?(@lower_hex_32, suffix)

  def canonical_capability_id?(_), do: false

  # ResourceOwner-only private mutable cell. The unnamed private table can be
  # read or written only by its owner process and disappears with that process.
  @spec new_private_cell(session_authority()) :: {:ok, :ets.tid()} | {:error, atom()}
  def new_private_cell(authority) when is_map(authority) do
    if valid_session_authority?(authority) do
      tid = :ets.new(__MODULE__, [:set, :private])

      true =
        :ets.insert(tid, {
          :authority,
          %{session: authority, mode: :route, active_turn: nil, poisoned: false}
        })

      {:ok, tid}
    else
      {:error, :invalid_authority}
    end
  rescue
    _ -> {:error, :invalid_authority}
  catch
    _, _ -> {:error, :invalid_authority}
  end

  @spec effect_authorizer(:ets.tid()) :: (atom(), route() -> :allow | {:error, atom()})
  def effect_authorizer(tid) do
    fn effect, route -> authorize_physical_effect(tid, effect, route) end
  end

  @spec activate_turn(:ets.tid(), map(), boolean()) :: :ok | {:error, atom()}
  def activate_turn(tid, lease, cleanup_registered?) when is_boolean(cleanup_registered?) do
    with {:ok, cell} <- read_cell(tid),
         false <- cell.poisoned,
         :route <- cell.mode,
         true <- is_nil(cell.active_turn),
         true <- valid_turn_lease?(cell.session, lease),
         true <- cleanup_registered? or lease.kind == :local do
      write_cell(tid, %{cell | mode: :turn, active_turn: lease})
    else
      _ -> {:error, :turn_activation_denied}
    end
  end

  @spec fence_and_drain(:ets.tid(), :session | String.t()) :: :ok | {:error, atom()}
  def fence_and_drain(tid, :session) do
    with {:ok, cell} <- read_cell(tid),
         :ok <- write_cell(tid, %{cell | mode: :fenced, active_turn: nil}) do
      if cell.poisoned, do: {:error, :owner_poisoned}, else: :ok
    end
  end

  def fence_and_drain(tid, turn_id) when is_binary(turn_id) do
    with {:ok, cell} <- read_cell(tid),
         true <- is_nil(cell.active_turn) or cell.active_turn.turn_id == turn_id,
         next_mode <- if(cell.poisoned, do: :poisoned, else: :route),
         :ok <- write_cell(tid, %{cell | mode: next_mode, active_turn: nil}) do
      if cell.poisoned, do: {:error, :owner_poisoned}, else: :ok
    else
      _ -> {:error, :fence_failed}
    end
  end

  def fence_and_drain(_tid, _scope), do: {:error, :fence_failed}

  @spec poison(:ets.tid()) :: :ok | {:error, atom()}
  def poison(tid) do
    with {:ok, cell} <- read_cell(tid) do
      write_cell(tid, %{cell | mode: :poisoned, poisoned: true})
    end
  end

  @spec poisoned?(:ets.tid()) :: boolean()
  def poisoned?(tid) do
    case read_cell(tid) do
      {:ok, %{poisoned: poisoned}} -> poisoned == true
      _ -> true
    end
  end

  defp authorize_physical_effect(tid, effect, route) when effect in @effects do
    with {:ok, cell} <- read_cell(tid),
         false <- cell.poisoned,
         true <- route == cell.session.route,
         :allow <- authorize_for_mode(cell, effect, route) do
      :allow
    else
      _ -> {:error, @authorization_error}
    end
  rescue
    _ -> {:error, @authorization_error}
  catch
    _, _ -> {:error, @authorization_error}
  end

  defp authorize_physical_effect(_tid, _effect, _route),
    do: {:error, @authorization_error}

  defp authorize_for_mode(%{mode: :route, session: %{kind: :local}}, effect, :none)
       when effect in @route_effects,
       do: :allow

  defp authorize_for_mode(%{mode: :route, session: %{kind: :external} = authority}, effect, route)
       when effect in @route_effects do
    authorize_route(authority, effect, route)
  end

  defp authorize_for_mode(
         %{mode: :turn, session: %{kind: :local}, active_turn: %{kind: :local}},
         effect,
         :none
       )
       when effect in @turn_effects,
       do: :allow

  defp authorize_for_mode(
         %{
           mode: :turn,
           session: %{kind: :external} = authority,
           active_turn: %{kind: :external} = lease
         },
         effect,
         route
       )
       when effect in @turn_effects do
    authorize_turn(authority, lease, effect, route)
  end

  defp authorize_for_mode(_cell, _effect, _route), do: {:error, @authorization_error}

  defp authorize_route(authority, effect, route) do
    trust_opts = route_opts(authority, route, :trusted, nil)

    with :allow <-
           safe_apply(authority.trust_module, :authorize_egress, [
             authority.agent_id,
             :external_provider,
             trust_opts
           ]),
         {:ok, :authorized} <-
           safe_apply(authority.security_module, :authorize, [
             authority.agent_id,
             authority.resource_uri,
             effect,
             [
               exact_capability_id: authority.route_capability_id,
               session_id: authority.session_id,
               task_id: nil,
               principal_scope: authority.human_id
             ]
           ]) do
      :allow
    else
      _ -> {:error, @authorization_error}
    end
  end

  defp authorize_turn(authority, lease, effect, route) do
    with {:ok, :authorized} <-
           safe_apply(authority.security_module, :authorize, [
             authority.agent_id,
             authority.resource_uri,
             effect,
             [
               exact_capability_id: authority.route_capability_id,
               session_id: authority.session_id,
               task_id: nil,
               principal_scope: authority.human_id
             ]
           ]),
         :allow <-
           safe_apply(authority.trust_module, :authorize_egress, [
             authority.agent_id,
             :external_provider,
             route_opts(authority, route, :untrusted, lease)
           ]),
         :ok <-
           safe_apply(authority.security_module, :validate_disclosure_capability, [
             authority.agent_id,
             lease.disclosure_capability_id,
             disclosure_validation_opts(authority, route, lease)
           ]) do
      :allow
    else
      _ -> {:error, @authorization_error}
    end
  end

  defp route_opts(authority, route, taint, nil) do
    [
      egress_taint: taint,
      egress_destination: route.destination,
      egress_provider: route.provider,
      egress_runtime: route.runtime,
      egress_model: route.model,
      session_id: authority.session_id,
      task_id: nil,
      principal_scope: authority.human_id
    ]
  end

  defp route_opts(authority, route, taint, lease) do
    [
      egress_taint: taint,
      egress_destination: route.destination,
      egress_provider: route.provider,
      egress_runtime: route.runtime,
      egress_model: route.model,
      disclosure_capability_id: lease.disclosure_capability_id,
      session_id: authority.session_id,
      task_id: lease.turn_id,
      principal_scope: authority.human_id
    ]
  end

  defp disclosure_validation_opts(authority, route, lease) do
    [
      session_id: authority.session_id,
      task_id: lease.turn_id,
      principal_scope: authority.human_id,
      egress_destination: route.destination,
      egress_provider: route.provider,
      egress_runtime: route.runtime,
      egress_model: route.model
    ]
  end

  defp valid_session_authority?(%{kind: :local, route: :none, session_id: session_id}),
    do: canonical_session_id?(session_id)

  defp valid_session_authority?(%{
         kind: :external,
         route: route,
         tier: :external_provider,
         agent_id: agent_id,
         human_id: human_id,
         session_id: session_id,
         resource_uri: resource_uri,
         route_capability_id: capability_id,
         security_module: security,
         trust_module: trust
       }) do
    route == @xai_route and is_binary(agent_id) and is_binary(human_id) and
      canonical_session_id?(session_id) and
      resource_uri == session_resource(session_id) and
      canonical_capability_id?(capability_id) and is_atom(security) and is_atom(trust)
  end

  defp valid_session_authority?(_), do: false

  defp valid_turn_lease?(%{kind: :local}, %{
         kind: :local,
         turn_id: turn_id,
         cleanup_key: {:voice_turn, turn_id}
       }),
       do: valid_turn_id?(turn_id)

  defp valid_turn_lease?(%{kind: :external}, %{
         kind: :external,
         turn_id: turn_id,
         disclosure_capability_id: capability_id,
         cleanup_key: {:voice_turn, turn_id}
       }) do
    valid_turn_id?(turn_id) and canonical_capability_id?(capability_id)
  end

  defp valid_turn_lease?(_authority, _lease), do: false

  defp valid_turn_id?("turn_" <> suffix) do
    byte_size(suffix) == 32 and String.match?(suffix, ~r/\A[0-9a-f]+\z/)
  end

  defp valid_turn_id?(_), do: false

  defp read_cell(tid) do
    case :ets.lookup(tid, :authority) do
      [{:authority, cell}] when is_map(cell) -> {:ok, cell}
      _ -> {:error, :authority_unavailable}
    end
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    _, _ -> {:error, :authority_unavailable}
  end

  defp write_cell(tid, cell) when is_map(cell) do
    case :ets.insert(tid, {:authority, cell}) do
      true -> :ok
      _ -> {:error, :authority_unavailable}
    end
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    _, _ -> {:error, :authority_unavailable}
  end

  defp safe_backend_route(backend) do
    backend.egress_route()
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp safe_classify(ai_module, route) do
    safe_apply(ai_module, :egress_tier_for, [
      route.provider,
      "https://" <> route.destination
    ])
  end

  defp canonical_route_shape?(route) when is_map(route) do
    MapSet.equal?(MapSet.new(Map.keys(route)), @route_keys) and
      Enum.all?(Map.values(route), &canonical_scalar?/1)
  end

  defp canonical_route_shape?(_), do: false

  defp canonical_scalar?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= 256 and String.valid?(value) and
      String.trim(value) == value and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp canonical_scalar?(_), do: false

  defp chat_resource(agent_id) when is_binary(agent_id),
    do: "arbor://chat/agent/" <> agent_id

  defp chat_resource(_), do: ""

  defp session_resource(session_id) when is_binary(session_id) do
    if canonical_session_id?(session_id) do
      @route_resource_prefix <> "/" <> session_id
    else
      nil
    end
  end

  defp session_resource(_), do: nil

  defp route_expiry(clock, reserved_ms) when is_function(clock, 0) do
    with %DateTime{} = now <- clock.(),
         true <- utc_datetime?(now) do
      seconds =
        reserved_ms
        |> Kernel.+(999)
        |> div(1_000)
        |> Kernel.+(@route_expiry_grace_seconds)
        |> min(@max_route_lifetime_seconds)

      {:ok, DateTime.add(now, seconds, :second)}
    else
      _ -> {:error, :invalid_clock}
    end
  rescue
    _ -> {:error, :invalid_clock}
  catch
    _, _ -> {:error, :invalid_clock}
  end

  defp route_expiry(_clock, _reserved_ms), do: {:error, :invalid_clock}

  defp utc_datetime?(%DateTime{
         calendar: Calendar.ISO,
         utc_offset: 0,
         std_offset: 0,
         time_zone: zone
       })
       when zone in ["Etc/UTC", "UTC"],
       do: true

  defp utc_datetime?(_), do: false

  defp admit_capability_id(id) when is_binary(id) do
    if canonical_capability_id?(id), do: {:ok, id}, else: {:invalid_capability_id, id}
  end

  defp admit_capability_id(_), do: {:error, :invalid_capability_id}

  defp capability_cleanup(%{
         security_module: security,
         route_capability_id: capability_id
       }),
       do: capability_cleanup(security, capability_id)

  defp capability_cleanup(security, capability_id) do
    fn -> revoke_capability(security, capability_id) end
  end

  defp revoke_capability(security, capability_id) do
    case safe_apply(security, :revoke, [capability_id]) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, :capability_revoke_failed}
    end
  end

  defp safe_apply(module, function, args)
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  rescue
    _ -> {:error, :collaborator_failed}
  catch
    _, _ -> {:error, :collaborator_failed}
  end

  defp safe_apply(_module, _function, _args), do: {:error, :collaborator_failed}
end
