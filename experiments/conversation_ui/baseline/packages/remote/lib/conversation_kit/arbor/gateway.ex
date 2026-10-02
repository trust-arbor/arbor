defmodule ConversationKit.Arbor.Gateway do
  @moduledoc """
  Private, renderer-neutral owner of one authenticated Gateway connection.

  A fresh Signature proof is acquired before each Kit operation. The wire has
  no response correlation IDs, so this owner permits one request at a time and
  retires its channel on timeout. It never retries a conversation operation.
  A new channel accepts only history; Kit.sync/1 supplies the attachment and
  preserves the client's expected-engagement fence.
  """
  use GenServer
  alias Arbor.Client.{Login, Signer, Socket}
  alias ConversationKit.Arbor.Gateway.Wire

  @default_timeout 5_000

  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    with :ok <- valid_options(opts), do: GenServer.start_link(__MODULE__, opts)
  rescue
    _ -> {:error, :invalid_options}
  end

  @doc "Trusted options for a private Kit/Demo owner, never renderer assigns."
  def client_options(pid), do: safe_call(pid, :client_options, 5_000)

  @doc "Close the channel; reattach through history unless the owned login was revoked."
  def disconnect(pid), do: safe_call(pid, :disconnect, 9_000)

  @doc "Retire the private connection owner and its channel."
  def close(pid) do
    GenServer.stop(pid, :normal, 9_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :conversation_unavailable}
  end

  @impl true
  def init(opts) do
    with :ok <- valid_options(opts) do
      # Linked Socket exits are explicitly handled; the separate lifetime
      # monitor also covers a normal exit of the trusted renderer/client owner.
      Process.flag(:trap_exit, true)
      Process.flag(:sensitive, true)
      owner = Keyword.fetch!(opts, :owner)

      {:ok,
       %{
         identity: Keyword.get(opts, :identity),
         session: Keyword.get(opts, :session),
         caller: if(opts[:session], do: opts[:session].principal, else: opts[:identity].agent_id),
         target: Keyword.fetch!(opts, :target),
         gateway_url: Keyword.fetch!(opts, :gateway_url),
         timeout: Keyword.get(opts, :request_timeout_ms, @default_timeout),
         owner: owner,
         owner_ref: Process.monitor(owner),
         socket: nil,
         socket_ref: nil,
         connected: false,
         attached: nil,
         generation: 0,
         fault: nil,
         pending: nil
       }}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(:client_options, _from, state) do
    pid = self()
    timeout = state.timeout

    options = [
      caller: state.caller,
      target: state.target,
      proof_provider: fn context -> safe_call(pid, {:proof, context}, timeout) end,
      adapter_options: [
        transport: fn context, proof -> request(pid, context, proof, timeout) end
      ],
      disconnect: fn -> disconnect(pid) end
    ]

    {:reply, {:ok, options}, state}
  end

  def handle_call({:proof, context}, _from, state) do
    result =
      if valid_context?(context, state) do
        proof(state, context)
      else
        {:error, :unauthorized}
      end

    {:reply, result, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = finish_pending(state, {:error, :conversation_unavailable})
    fault = if state.fault == :unauthorized, do: :unauthorized
    {:reply, :ok, retire_channel(%{state | fault: fault})}
  end

  def handle_call({:request, tag, deadline, context, proof}, from, state) do
    cond do
      not Process.alive?(elem(from, 0)) or now() >= deadline ->
        {:reply, {:error, :transport_timeout}, state}

      not valid_context?(context, state) ->
        {:reply, {:error, :unauthorized}, state}

      state.fault != nil ->
        {:reply, {:error, state.fault}, state}

      state.pending != nil ->
        {:reply, {:error, :transport_busy}, state}

      context.operation != :history and state.attached == nil ->
        {:reply, {:error, :transport_not_attached}, state}

      state.attached != nil and context.options[:expected_engagement_id] != state.attached ->
        {:reply, {:error, :conversation_scope_changed}, retire_channel(state)}

      true ->
        begin_request(state, from, tag, deadline, context, proof)
    end
  end

  # A malformed call must not put credential-bearing arguments in an exception stacktrace.
  def handle_call(_request, _from, state),
    do: {:stop, :invalid_request, {:error, :invalid_request}, state}

  defp begin_request(state, from, tag, deadline, context, proof) do
    with {:ok, frame} <- frame(state, context, proof),
         {:ok, state} <- ensure_channel(state) do
      pending = %{
        tag: tag,
        from: from,
        caller_ref: Process.monitor(elem(from, 0)),
        timer: Process.send_after(self(), {:deadline, tag}, max(deadline - now(), 0)),
        deadline: deadline,
        context: context,
        frame: frame,
        sent: false,
        generation: state.generation
      }

      {:noreply, maybe_send(%{state | pending: pending})}
    else
      {:error, :unauthorized} -> {:reply, {:error, :unauthorized}, state}
      _ -> {:reply, {:error, :conversation_unavailable}, retire_channel(state)}
    end
  end

  @impl true
  def handle_info({:arbor_socket, pid, :connected}, %{socket: pid} = state),
    do: {:noreply, maybe_send(%{state | connected: true})}

  def handle_info({:arbor_socket, pid, {:frame, binary}}, %{socket: pid} = state) do
    # This closed control envelope is the sole unsolicited session event. It
    # invalidates the owned login even between requests, without asserting that
    # an already-sent command had no effect. Old socket generations cannot enter.
    if state.session != nil and is_binary(binary) and byte_size(binary) <= 256 and
         Wire.decode(binary, nil) == {:error, :unauthorized},
       do: {:noreply, fail_channel(state, :unauthorized)},
       else: receive_frame(binary, state)
  end

  def handle_info(
        {:arbor_socket, pid, {:closed, :unauthorized}},
        %{socket: pid, session: session} = state
      )
      when not is_nil(session),
      do: {:noreply, fail_channel(state, :unauthorized)}

  def handle_info({:arbor_socket, pid, {:closed, _}}, %{socket: pid} = state),
    do: {:noreply, fail_channel(state, :conversation_unavailable)}

  def handle_info({:deadline, tag}, %{pending: %{tag: tag}} = state),
    do: {:noreply, fail_channel(state, :transport_timeout)}

  def handle_info({:expire, tag}, %{pending: %{tag: tag}} = state),
    do: {:noreply, fail_channel(state, :transport_timeout)}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{pending: %{caller_ref: ref}} = state),
    do: {:noreply, fail_channel(state, :conversation_unavailable)}

  def handle_info({:DOWN, ref, :process, _, _}, %{socket_ref: ref} = state),
    do: {:noreply, fail_channel(state, :conversation_unavailable)}

  def handle_info({:EXIT, pid, _}, %{socket: pid} = state),
    do: {:noreply, fail_channel(state, :conversation_unavailable)}

  # Retired generations may still have exit/frame messages in this mailbox.
  def handle_info({:arbor_socket, _, _}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, reason}, state), do: {:stop, reason, state}
  def handle_info(_, state), do: {:noreply, state}

  defp receive_frame(binary, state) do
    case state.pending do
      %{sent: true, generation: generation} = pending when generation == state.generation ->
        if now() >= pending.deadline do
          {:noreply, fail_channel(state, :transport_timeout)}
        else
          result = Wire.decode(binary, pending.context)
          next = update_attachment(state, pending.context, result)
          next = finish_pending(next, result)

          cond do
            result == {:error, :unauthorized} and state.session != nil ->
              {:noreply, fail_channel(next, :unauthorized)}

            result in [
              {:error, :invalid_transport_response},
              {:error, :unauthorized},
              {:error, :conversation_scope_changed},
              {:error, :transport_not_attached}
            ] ->
              {:noreply, retire_channel(next)}

            true ->
              {:noreply, next}
          end
        end

      _ ->
        # There are no unsolicited conversation messages in this protocol.
        {:noreply, fail_channel(state, :invalid_transport_response)}
    end
  end

  @impl true
  def terminate(_, state) do
    state |> finish_pending({:error, :conversation_unavailable}) |> retire_channel()
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:log, _value} -> {:log, []}
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted_client_state}
      pair -> pair
    end)
  end

  defp request(pid, context, proof, timeout) do
    tag = make_ref()
    deadline = now() + timeout

    try do
      GenServer.call(pid, {:request, tag, deadline, context, proof}, timeout + 1_000)
    catch
      :exit, {:timeout, _} ->
        send(pid, {:expire, tag})
        {:error, :transport_timeout}

      :exit, _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp ensure_channel(%{socket: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_channel(state) do
    auth = if state.session, do: [session: state.session], else: [identity: state.identity]

    case Socket.start_link([owner: self(), gateway_url: state.gateway_url] ++ auth) do
      {:ok, pid} ->
        # Socket monitors this owner independently. Unlink before later
        # retirement so delayed EXIT messages cannot kill a new generation.
        Process.unlink(pid)

        {:ok,
         %{
           state
           | socket: pid,
             socket_ref: Process.monitor(pid),
             generation: state.generation + 1
         }}

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp maybe_send(%{connected: true, pending: %{sent: false} = pending} = state) do
    cond do
      now() >= pending.deadline or not Process.alive?(elem(pending.from, 0)) ->
        fail_channel(state, :transport_timeout)

      true ->
        case Socket.send_frame(state.socket, pending.frame, pending.deadline) do
          :ok -> %{state | pending: %{pending | sent: true, frame: nil}}
          {:error, :timeout} -> fail_channel(state, :transport_timeout)
          _ -> fail_channel(state, :conversation_unavailable)
        end
    end
  end

  defp maybe_send(state), do: state

  defp update_attachment(state, %{operation: :history}, {:ok, %{engagement_id: engagement}}),
    do: %{state | attached: engagement}

  defp update_attachment(state, _, _), do: state

  defp fail_channel(state, reason) do
    state =
      if reason == :invalid_transport_response or
           (reason == :unauthorized and state.session != nil),
         do: %{state | fault: reason},
         else: state

    state |> finish_pending({:error, reason}) |> retire_channel()
  end

  defp finish_pending(%{pending: nil} = state, _), do: state

  defp finish_pending(%{pending: pending} = state, reply) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.caller_ref, [:flush])
    GenServer.reply(pending.from, reply)
    %{state | pending: nil}
  end

  defp retire_channel(state) do
    if state.socket do
      case Socket.close(state.socket) do
        :ok -> :ok
        _ -> Process.exit(state.socket, :kill)
      end

      if Process.alive?(state.socket) do
        Process.exit(state.socket, :kill)

        receive do
          {:DOWN, ref, :process, pid, _}
          when ref == state.socket_ref and pid == state.socket ->
            :ok
        after
          1_000 -> exit(:socket_cleanup_pending)
        end
      end

      Process.demonitor(state.socket_ref, [:flush])
    end

    %{state | socket: nil, socket_ref: nil, connected: false, attached: nil}
  end

  defp safe_call(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _ -> {:error, :conversation_unavailable}
  end

  defp valid_context?(context, state) do
    is_map(context) and map_size(context) == 5 and
      context[:caller] == state.caller and context[:target] == state.target and
      context[:operation] in [:history, :events, :command, :submit] and
      Keyword.keyword?(context[:options])
  rescue
    _ -> false
  end

  defp valid_options(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Enum.all?(
             Keyword.keys(opts),
             &(&1 in [:identity, :session, :target, :gateway_url, :owner, :request_timeout_ms])
           ),
         true <- length(opts) == length(Enum.uniq(Keyword.keys(opts))),
         true <- valid_auth?(opts),
         true <- is_binary(opts[:target]) and is_binary(opts[:gateway_url]),
         true <- is_pid(opts[:owner]) and Process.alive?(opts[:owner]),
         timeout = Keyword.get(opts, :request_timeout_ms, @default_timeout),
         true <- is_integer(timeout) and timeout in 1..60_000 do
      :ok
    else
      _ -> {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp valid_auth?(opts) do
    case {Keyword.has_key?(opts, :identity), Keyword.has_key?(opts, :session)} do
      {true, false} ->
        Signer.valid_identity?(opts[:identity])

      {false, true} ->
        case Login.session(opts[:session]) do
          {:ok, session} -> session.target == opts[:target]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp proof(%{fault: :unauthorized}, _context), do: {:error, :unauthorized}

  defp proof(%{session: nil} = state, context),
    do:
      {:ok,
       [signed_request: Signer.authorization_for_payload(state.identity, Wire.payload(context))]}

  defp proof(state, _context) do
    case Login.session(state.session) do
      {:ok, session} -> {:ok, [session_token: session.credential]}
      _ -> {:error, :unauthorized}
    end
  end

  defp frame(%{session: nil}, context, proof), do: Wire.frame(context, proof)

  defp frame(state, context, proof) do
    with {:ok, session} <- Login.session(state.session),
         true <- proof == [session_token: session.credential] do
      Wire.session_frame(context)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
