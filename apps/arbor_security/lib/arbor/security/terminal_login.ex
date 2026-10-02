defmodule Arbor.Security.TerminalLogin do
  @moduledoc false
  use GenServer

  alias Arbor.Security
  alias Arbor.Security.OIDC.{Config, IdentityStore, TokenVerifier}
  alias Arbor.Security.SessionToken

  @denied {:error, :unauthorized}
  @unavailable {:error, :login_unavailable}
  @start_timeout_ms 30_000
  @call_timeout_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def begin(target),
    do: call({:begin, target, now_ms() + @start_timeout_ms}, @start_timeout_ms + 5_000)

  def status(handle), do: call({:status, handle})
  def cancel(handle), do: call({:cancel, handle})
  def preflight(credential), do: call({:preflight, credential})
  def claim(credential), do: call({:claim, credential, now_ms() + @call_timeout_ms})
  def verify(credential), do: call({:verify, credential})
  def revoke(credential), do: call({:revoke, credential})

  defp call(message, timeout \\ @call_timeout_ms) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> @denied
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    {:ok, %{flows: %{}, sessions: %{}, options: Security.Config.terminal_login_options()}}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} ->
        {:log, []}

      {key, _value} when key in [:state, :message, :reason] ->
        {key, :redacted_terminal_login}

      pair ->
        pair
    end)
  end

  @impl true
  def handle_call({:begin, target, start_deadline}, from, state) do
    provider = Config.device_flow()

    cond do
      not target?(target) ->
        {:reply, @denied, state}

      start_deadline <= now_ms() or not Process.alive?(elem(from, 0)) ->
        {:reply, @unavailable, state}

      not provider?(provider) or map_size(state.flows) >= state.options.max_pending or
          map_size(state.sessions) >= state.options.max_active ->
        {:reply, @unavailable, state}

      true ->
        handle = random_token()
        key = digest(handle)
        owner = self()
        deadline = now_ms() + state.options.pending_seconds * 1_000
        options = state.options

        {pid, monitor} =
          :erlang.spawn_opt(
            fn -> run_flow(owner, key, target, provider, options) end,
            [:link, :monitor]
          )

        caller_monitor = Process.monitor(elem(from, 0))
        timer_tag = make_ref()

        timer =
          Process.send_after(
            self(),
            {:flow_expire, key, timer_tag},
            min(remaining(start_deadline), remaining(deadline))
          )

        flow = %{
          pid: pid,
          monitor: monitor,
          caller_monitor: caller_monitor,
          from: from,
          handle: handle,
          target: target,
          deadline: deadline,
          start_deadline: start_deadline,
          timer: timer,
          timer_tag: timer_tag,
          stage: :starting,
          outcome: nil,
          waiters: []
        }

        {:noreply, put_in(state.flows[key], flow)}
    end
  end

  def handle_call({:status, handle}, _from, state) do
    case fetch_flow(state, handle) do
      {key, %{stage: :ready, outcome: {:ok, binding}} = flow} ->
        state = drop_flow(state, key, flow)

        if map_size(state.sessions) < state.options.max_active and binding_valid?(binding) and
             flow.deadline > now_ms() do
          credential = random_token()
          session_key = digest(credential)

          session =
            binding
            |> Map.merge(%{phase: :unclaimed, owner_pid: nil, owner_ref: nil})
            |> schedule_session_expiry(session_key, state.options.attach_seconds)

          state = put_in(state.sessions[session_key], session)

          reply =
            Map.take(binding, [:principal, :target, :lifetime])
            |> Map.put(:credential, credential)

          {:reply, {:ok, reply}, state}
        else
          {:reply, @denied, state}
        end

      {key, flow} ->
        if flow.deadline > now_ms() and flow.stage in [:starting, :polling, :settling] do
          {:reply, {:ok, :pending}, state}
        else
          {:reply, @denied, retire_flow(state, key, flow)}
        end

      nil ->
        {:reply, @denied, state}
    end
  end

  def handle_call({:cancel, handle}, from, state) do
    case fetch_flow(state, handle) do
      {key, %{pid: pid} = flow} when is_pid(pid) ->
        flow = %{flow | waiters: [from | flow.waiters]}
        {:noreply, retire_flow(state, key, flow)}

      {key, flow} ->
        {:reply, :ok, drop_flow(state, key, flow)}

      nil ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:preflight, credential}, _from, state) do
    state = detach_dead_owner(state, credential)

    case fetch_session(state, credential) do
      {key, %{phase: :attached} = binding} ->
        if binding_valid?(binding) do
          if Process.alive?(binding.owner_pid) do
            {:reply, {:error, :session_in_use}, state}
          else
            detached = detach_session(binding, key, state.options.reconnect_seconds)
            {:reply, {:ok, metadata(detached)}, put_in(state.sessions[key], detached)}
          end
        else
          {:reply, @denied, drop_session(state, key, binding)}
        end

      {key, %{phase: phase} = binding} when phase in [:unclaimed, :detached] ->
        if attachable?(binding) and binding_valid?(binding) and attachable?(binding) do
          {:reply, {:ok, metadata(binding)}, state}
        else
          {:reply, @denied, drop_session(state, key, binding)}
        end

      _ ->
        {:reply, @denied, state}
    end
  end

  def handle_call({:claim, credential, deadline}, {caller, _}, state) do
    state = detach_dead_owner(state, credential)

    case fetch_session(state, credential) do
      {key, %{phase: :attached, owner_pid: ^caller} = binding} ->
        cond do
          not live_call?(caller, deadline) ->
            {:reply, @denied, state}

          not binding_valid?(binding) ->
            {:reply, @denied, drop_session(state, key, binding)}

          live_call?(caller, deadline) ->
            {:reply, {:ok, metadata(binding)}, state}

          true ->
            {:reply, @denied, state}
        end

      {key, %{phase: phase} = binding} when phase in [:unclaimed, :detached] ->
        cond do
          not live_call?(caller, deadline) ->
            {:reply, @denied, state}

          not attachable?(binding) or not binding_valid?(binding) or not attachable?(binding) ->
            {:reply, @denied, drop_session(state, key, binding)}

          not live_call?(caller, deadline) ->
            {:reply, @denied, state}

          true ->
            cancel_session_timer(binding)
            ref = Process.monitor(caller)

            attached = %{
              binding
              | phase: :attached,
                owner_pid: caller,
                owner_ref: ref,
                deadline: nil,
                timer: nil,
                timer_tag: nil
            }

            {:reply, {:ok, metadata(attached)}, put_in(state.sessions[key], attached)}
        end

      _ ->
        # A duplicate claim from another process must not retire its live owner.
        {:reply, @denied, state}
    end
  end

  def handle_call({:verify, credential}, {caller, _}, state) do
    state = detach_dead_owner(state, credential)

    case fetch_session(state, credential) do
      {key, %{phase: :attached, owner_pid: ^caller} = binding} ->
        with true <- Process.alive?(caller) and binding_valid?(binding),
             {:ok, proof} <- SessionToken.generate_conversation(binding.principal, binding.target),
             true <- binding_valid?(binding) and Process.alive?(caller) do
          {:reply, {:ok, Map.put(metadata(binding), :session_token, proof)}, state}
        else
          _ -> {:reply, @denied, drop_session(state, key, binding)}
        end

      _ ->
        # Possession permits reconnect, not use from outside the claimed socket.
        {:reply, @denied, state}
    end
  end

  def handle_call({:revoke, credential}, _from, state) do
    state =
      if token?(credential) do
        key = digest(credential)

        case state.sessions[key] do
          nil -> state
          binding -> drop_session(state, key, binding)
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  # A malformed private request must not crash this shared owner and expose
  # credential-bearing arguments through an exception stack trace.
  def handle_call(_request, _from, state), do: {:reply, @denied, state}

  @impl true
  def handle_info({:flow_started, key, pid, public}, state) do
    case state.flows[key] do
      %{pid: ^pid, stage: :starting} = flow ->
        if flow.deadline > now_ms() and flow.start_deadline > now_ms() and
             Process.alive?(elem(flow.from, 0)) do
          Process.cancel_timer(flow.timer)
          Process.demonitor(flow.caller_monitor, [:flush])
          deadline = min(flow.deadline, now_ms() + public.expires_in * 1_000)
          timer_tag = make_ref()
          timer = Process.send_after(self(), {:flow_expire, key, timer_tag}, remaining(deadline))
          public = %{public | expires_in: max(div(remaining(deadline), 1_000), 1)}
          GenServer.reply(flow.from, {:ok, Map.put(public, :handle, flow.handle)})

          flow = %{
            flow
            | stage: :polling,
              from: nil,
              handle: nil,
              caller_monitor: nil,
              deadline: deadline,
              timer: timer,
              timer_tag: timer_tag
          }

          {:noreply, put_in(state.flows[key], flow)}
        else
          {:noreply, retire_flow(state, key, flow)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:flow_result, key, pid, outcome}, state) do
    case state.flows[key] do
      %{pid: ^pid, stage: :polling} = flow ->
        {:noreply, put_in(state.flows[key], %{flow | outcome: outcome, stage: :settling})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Enum.find(state.flows, fn {_key, flow} -> flow.monitor == monitor and flow.pid == pid end) do
      {key, flow} ->
        Enum.each(flow.waiters, &GenServer.reply(&1, :ok))

        if reason == :normal and flow.stage == :settling and match?({:ok, _}, flow.outcome) and
             flow.deadline > now_ms() do
          {:noreply, put_in(state.flows[key], %{flow | pid: nil, monitor: nil, stage: :ready})}
        else
          {:noreply, drop_flow(state, key, flow)}
        end

      nil ->
        {:noreply, owner_down(state, monitor, pid)}
    end
  end

  def handle_info({:flow_expire, key, timer_tag}, state) do
    case state.flows[key] do
      %{timer_tag: ^timer_tag} = flow -> {:noreply, retire_flow(state, key, flow)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:session_expire, key, tag}, state) do
    case state.sessions[key] do
      %{phase: phase, timer_tag: ^tag, deadline: deadline} = binding
      when phase in [:unclaimed, :detached] ->
        if deadline <= now_ms(),
          do: {:noreply, drop_session(state, key, binding)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Linked workers also die with an untrappable broker crash. On orderly
    # shutdown, wait for their exact monitors before publishing owner retirement.
    Enum.each(state.flows, fn {_key, flow} ->
      if is_pid(flow.pid) do
        Process.exit(flow.pid, :kill)

        receive do
          {:DOWN, ref, :process, pid, _} when ref == flow.monitor and pid == flow.pid -> :ok
        end
      end
    end)

    :ok
  end

  defp run_flow(owner, key, target, provider, options) do
    Process.flag(:sensitive, true)

    result =
      try do
        provider = Map.put(provider, :poll_timeout_ms, options.pending_seconds * 1_000)

        with {:ok, response} <- options.device_flow_module.start(provider),
             {:ok, public} <- public_device_response(response, provider) do
          send(owner, {:flow_started, key, self(), public})

          with {:ok, %{"id_token" => token}} <-
                 options.device_flow_module.poll(provider, response),
               true <- is_binary(token) and byte_size(token) in 1..16_384,
               {:ok, claims} <- TokenVerifier.verify(token, provider),
               :ok <- validate_claims(claims, provider),
               principal = IdentityStore.derive_agent_id(claims),
               {:ok, canonical} <- Security.resolve_conversation_owner(principal),
               {:ok, :authorized} <-
                 Security.recheck_conversation_owner(principal, target, canonical),
               :ok <- validate_claims(claims, provider) do
            {:ok,
             %{
               principal: principal,
               target: target,
               owner: canonical,
               lifetime: :connection
             }}
          else
            _ -> @denied
          end
        else
          _ -> @denied
        end
      rescue
        _ -> @denied
      catch
        _, _ -> @denied
      end

    send(owner, {:flow_result, key, self(), result})
  end

  defp public_device_response(response, provider) when is_map(response) do
    uri = response["verification_uri"]
    code = response["user_code"]
    expires = response["expires_in"]
    interval = response["interval"] || 5

    if safe_uri?(uri, provider) and is_binary(code) and byte_size(code) in 1..128 and
         Regex.match?(~r/\A[ -~]+\z/, code) and is_integer(expires) and expires in 1..86_400 and
         is_integer(interval) and interval in 1..60 do
      {:ok, %{verification_uri: uri, user_code: code, expires_in: expires, interval: interval}}
    else
      @denied
    end
  end

  defp public_device_response(_, _), do: @denied

  # This URL is displayed for the user's browser; no credential is sent to it.
  # Local HTTP still requires the host's explicit/resolved OIDC policy.
  defp safe_uri?(uri, provider) when is_binary(uri) and byte_size(uri) in 1..2_048 do
    parsed = URI.parse(uri)

    not Regex.match?(~r/[\x00-\x20\x7f]/, uri) and is_nil(parsed.userinfo) and
      is_nil(parsed.fragment) and
      is_binary(parsed.host) and parsed.host != "" and is_integer(parsed.port) and
      parsed.port in 1..65_535 and
      (parsed.scheme == "https" or
         (parsed.scheme == "http" and provider[:allow_http] == true and
            parsed.host in ["localhost", "127.0.0.1", "::1"]))
  end

  defp safe_uri?(_, _), do: false

  defp validate_claims(claims, provider) when is_map(claims) do
    now = now_seconds()
    aud = claims["aud"]
    audience = if is_binary(aud), do: [aud], else: aud
    azp = claims["azp"]
    nbf = claims["nbf"]
    iat = claims["iat"]

    if bounded_string?(claims["iss"], 2_048) and claims["iss"] == provider.issuer and
         bounded_string?(claims["sub"], 256) and is_integer(claims["exp"]) and
         claims["exp"] > now and claims["exp"] <= 253_402_300_799 and
         (not Map.has_key?(claims, "nbf") or (is_integer(nbf) and nbf >= 0 and nbf <= now)) and
         (not Map.has_key?(claims, "iat") or (is_integer(iat) and iat >= 0 and iat <= now)) and
         is_list(audience) and length(audience) in 1..16 and
         Enum.all?(audience, &bounded_string?(&1, 256)) and provider.client_id in audience and
         (not Map.has_key?(claims, "azp") or azp == provider.client_id) and
         (length(audience) == 1 or azp == provider.client_id) do
      :ok
    else
      @denied
    end
  end

  defp validate_claims(_, _), do: @denied

  defp binding_valid?(binding) do
    Security.recheck_conversation_owner(binding.principal, binding.target, binding.owner) ==
      {:ok, :authorized}
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp retire_flow(state, key, flow) do
    if is_pid(flow.pid) do
      Process.exit(flow.pid, :kill)
      put_in(state.flows[key], %{flow | stage: :retiring, outcome: nil})
    else
      drop_flow(state, key, flow)
    end
  end

  defp drop_flow(state, key, flow) do
    Process.cancel_timer(flow.timer)
    if flow.caller_monitor, do: Process.demonitor(flow.caller_monitor, [:flush])
    if flow.from, do: GenServer.reply(flow.from, @denied)
    %{state | flows: Map.delete(state.flows, key)}
  end

  defp drop_session(state, key, binding) do
    cancel_session_timer(binding)
    if binding.owner_ref, do: Process.demonitor(binding.owner_ref, [:flush])
    %{state | sessions: Map.delete(state.sessions, key)}
  end

  defp metadata(binding), do: Map.take(binding, [:principal, :target, :owner, :lifetime])

  defp fetch_session(state, credential) do
    if token?(credential) do
      key = digest(credential)

      case state.sessions[key] do
        nil -> nil
        binding -> {key, binding}
      end
    end
  end

  defp attachable?(%{phase: phase, deadline: deadline}) when phase in [:unclaimed, :detached],
    do: deadline > now_ms()

  defp live_call?(caller, deadline),
    do: is_integer(deadline) and Process.alive?(caller) and deadline > now_ms()

  defp cancel_session_timer(%{timer: timer}) when is_reference(timer),
    do: Process.cancel_timer(timer)

  defp cancel_session_timer(_), do: :ok

  defp schedule_session_expiry(binding, key, seconds) do
    tag = make_ref()
    deadline = now_ms() + seconds * 1_000
    timer = Process.send_after(self(), {:session_expire, key, tag}, remaining(deadline))
    Map.merge(binding, %{deadline: deadline, timer: timer, timer_tag: tag})
  end

  defp owner_down(state, ref, pid) do
    case Enum.find(state.sessions, fn {_key, binding} ->
           binding.phase == :attached and binding.owner_ref == ref and binding.owner_pid == pid
         end) do
      {key, binding} ->
        detached = detach_session(binding, key, state.options.reconnect_seconds)
        put_in(state.sessions[key], detached)

      nil ->
        case Enum.find(state.flows, fn {_key, flow} -> flow.caller_monitor == ref end) do
          {key, flow} -> retire_flow(state, key, flow)
          nil -> state
        end
    end
  end

  # A new upgrade can race the monitor message after the previous process has
  # already died. Process liveness is authoritative; consume this generation
  # once and ignore its eventual stale DOWN after a replacement attaches.
  defp detach_dead_owner(state, credential) do
    case fetch_session(state, credential) do
      {key, %{phase: :attached, owner_pid: pid} = binding} ->
        if Process.alive?(pid) do
          state
        else
          detached = detach_session(binding, key, state.options.reconnect_seconds)
          put_in(state.sessions[key], detached)
        end

      _ ->
        state
    end
  end

  defp detach_session(binding, key, seconds) do
    Process.demonitor(binding.owner_ref, [:flush])

    %{binding | phase: :detached, owner_ref: nil, owner_pid: nil}
    |> schedule_session_expiry(key, seconds)
  end

  defp fetch_flow(state, handle) do
    if token?(handle) do
      key = digest(handle)

      case state.flows[key] do
        nil -> nil
        flow -> {key, flow}
      end
    end
  end

  defp provider?(%{issuer: issuer, client_id: client}) do
    bounded_string?(issuer, 2_048) and bounded_string?(client, 256)
  end

  defp provider?(_), do: false

  defp bounded_string?(v, max),
    do:
      is_binary(v) and byte_size(v) in 1..max and String.valid?(v) and
        not String.contains?(v, <<0>>)

  defp target?(v),
    do: bounded_string?(v, 256) and Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, v)

  defp token?(v),
    do: is_binary(v) and byte_size(v) == 43 and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, v)

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_seconds, do: System.os_time(:second)
  defp remaining(deadline), do: max(deadline - now_ms(), 0)
end
