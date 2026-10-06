defmodule Arbor.Gateway.Chat.Socket do
  @moduledoc """
  Authenticated conversation transport. The upgrade identifies the socket; every
  signed operation carries a fresh, operation-bound signature consumed once by
  Agent. Terminal sessions instead retain a server-scoped credential and recheck
  its current binding before admission and before publishing each result.

  History and command-journal pages have independent cursors. No agent-wide
  signal is a private transcript, and no socket attachment grants capabilities.
  Durable cancellation and source-owned choices use separately bound operations.
  Terminal credentials authorize chat; protected approval still requires a
  general human session and its original approval capability. Legacy controls
  and server slash commands remain unavailable.
  """
  @behaviour WebSock
  alias Arbor.Gateway.Chat.Protocol
  alias Arbor.Gateway.Chat.TerminalLogin

  @binding_keys [:principal, :target, :owner, :lifetime]
  @keepalive_defaults %{interval_ms: 30_000, timeout_ms: 10_000, idle_timeout_ms: 120_000}

  @doc false
  def keepalive_options do
    opts = Application.get_env(:arbor_gateway, :terminal_session_keepalive, [])

    if is_list(opts) and Keyword.keyword?(opts) do
      values =
        Map.new(@keepalive_defaults, fn {key, default} ->
          {key, Keyword.get(opts, key, default)}
        end)

      if Enum.all?(values, fn {key, value} ->
           is_integer(value) and value >= 1 and value <= @keepalive_defaults[key]
         end) and values.interval_ms + values.timeout_ms < values.idle_timeout_ms,
         do: values,
         else: @keepalive_defaults
    else
      @keepalive_defaults
    end
  end

  @impl true
  def init(%{auth_mode: :conversation_session, credential: credential} = state) do
    Process.flag(:sensitive, true)
    public = state |> Map.delete(:credential) |> Map.delete(:session_token) |> initial_state()
    public = Map.merge(public, %{credential_table: nil, keepalive: nil})

    # Claim in the actual WebSock process, never in the HTTP preflight owner.
    with {:ok, binding} <- TerminalLogin.claim(credential),
         true <- Map.take(binding, @binding_keys) == Map.take(public, @binding_keys) do
      table = :ets.new(__MODULE__, [:set, :private])
      true = :ets.insert(table, {:credential, credential})
      {:ok, schedule_ping(%{public | credential_table: table})}
    else
      _ -> close_session(public, :unauthorized)
    end
  end

  def init(state), do: {:ok, initial_state(state)}

  defp initial_state(state),
    do: Map.merge(%{agent_id: nil, engagement_id: nil, invalidated?: false}, state)

  @impl true
  def handle_in(_frame, %{auth_mode: :conversation_session, invalidated?: true} = state),
    do: close_session(state, :unauthorized)

  def handle_in(_frame, %{invalidated?: true} = state),
    do: push({:error, :conversation_scope_changed}, state)

  def handle_in({text, [opcode: :text]}, %{auth_mode: :conversation_session} = state) do
    with {:ok, binding} <- session_binding(state),
         {:ok, request} <- Protocol.decode_session(text),
         true <- request.caller == state.principal and request.target == state.target,
         :ok <- attached_scope(request, state) do
      dispatch(Map.put(request, :session_token, binding.session_token), state)
    else
      false -> push({:error, :unauthorized}, state)
      {:error, reason} -> push({:error, reason}, state)
    end
  end

  def handle_in({text, [opcode: :text]}, state) do
    with {:ok, request} <- Protocol.decode_authenticated(text),
         true <- request.proof.agent_id == state.principal,
         :ok <- attached_scope(request, state) do
      dispatch(request, state)
    else
      false -> push({:error, :unauthorized}, state)
      {:error, reason} -> push({:error, reason}, state)
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  defp dispatch(request, state) do
    case do_dispatch(request, state) do
      {:push, messages, latest} -> {:push, messages, rearm_pong_after_dispatch(latest)}
      result -> result
    end
  end

  # A fresh read is also the attachment operation. The host chooses the private
  # engagement from authenticated ownership, never from a client routing field.
  defp do_dispatch(%{operation: operation} = req, state) when operation in [:history, :window] do
    function = if operation == :window, do: :conversation_window, else: :conversation_history

    case call(function, [state.principal, req.target, proof_opts(req)]) do
      {:ok, page} ->
        event = if operation == :window, do: :conversation_window, else: :conversation_history

        # Remote renderers additionally verify the socket's authenticated target.
        data = Map.put(page, :agent_id, req.target)

        push({event, data}, %{
          state
          | agent_id: req.target,
            engagement_id: page.engagement_id
        })

      {:error, reason} ->
        push({:error, reason}, state)
    end
  end

  defp do_dispatch(%{target: target}, %{agent_id: attached} = state) when target != attached,
    do: push({:error, :not_attached}, state)

  defp do_dispatch(%{operation: :notices} = req, state) do
    case call(:conversation_notices, [state.principal, req.target, proof_opts(req)]) do
      {:ok, page} when is_map(page) ->
        cond do
          page[:target_agent_id] != state.agent_id or page[:engagement_id] != state.engagement_id ->
            push({:error, :conversation_scope_changed}, state)

          not notice_page_fields?(page) or private_control_fields?(page) ->
            push({:error, :conversation_unavailable}, state)

          byte_size(Protocol.encode({:conversation_notices, page})) > 131_072 ->
            push({:error, :page_too_large}, state)

          true ->
            # The facade owns authorization and the closed notice page. Preserve
            # its shape; the SDK uses target_agent_id rather than added agent_id.
            push({:conversation_notices, page}, state)
        end

      {:error, reason} ->
        push({:error, reason}, state)

      _ ->
        push({:error, :conversation_unavailable}, state)
    end
  end

  defp do_dispatch(%{operation: :submit, input: %{text: "/" <> _}} = _req, state),
    do: push({:error, :server_commands_unavailable}, state)

  defp do_dispatch(%{operation: :submit} = req, state) do
    result =
      call(:submit_conversation_command, [state.principal, req.target, req.input, proof_opts(req)])

    case result do
      {:error, reason}
      when reason in [
             :unsupported_conversation_capability,
             :invalid_command,
             :command_conflict,
             :agent_not_running
           ] ->
        push({:conversation_rejected, %{id: req.input.id, reason: reason}}, state)

      _ ->
        publish(result, :conversation_command, state)
    end
  end

  defp do_dispatch(%{operation: :command} = req, state) do
    result =
      call(:conversation_command, [state.principal, req.target, req.input, proof_opts(req)])

    publish(result, :conversation_command, state)
  end

  defp do_dispatch(%{operation: :events} = req, state) do
    result = call(:conversation_events, [state.principal, req.target, req.input, proof_opts(req)])
    publish(result, :conversation_events, state)
  end

  defp do_dispatch(%{operation: :activity} = req, state) do
    result = call(:conversation_activity, [state.principal, req.target, proof_opts(req)])
    publish_control(result, :conversation_activity, req, state)
  end

  defp do_dispatch(%{operation: :cancel} = req, state) do
    result =
      call(:cancel_conversation_command, [state.principal, req.target, req.input, proof_opts(req)])

    publish_control(result, :conversation_cancellation, req, state)
  end

  defp do_dispatch(%{operation: :interactions} = req, state) do
    result =
      call(:conversation_interactions, [state.principal, req.target, req.input, proof_opts(req)])

    publish_control(result, :conversation_interactions, req, state)
  end

  defp do_dispatch(
         %{operation: :interaction_approval},
         %{auth_mode: :conversation_session} = state
       ),
       do: push({:error, :approval_answer_required}, state)

  defp do_dispatch(%{operation: operation} = req, state)
       when operation in [:interaction_choice, :interaction_approval] do
    function =
      if operation == :interaction_choice,
        do: :answer_conversation_choice,
        else: :answer_conversation_approval

    result = call(function, [state.principal, req.target, req.input, proof_opts(req)])
    publish_control(result, :conversation_interaction_answer, req, state)
  end

  # Only host-returned scope and exact accepted selectors can correlate a reply.
  # No renderer-supplied engagement, label or cached prompt establishes authority.
  defp publish_control({:ok, value}, type, req, state) when is_map(value) do
    with true <- value[:engagement_id] == state.engagement_id,
         true <- correlated_control?(req, value),
         data = Map.put(value, :agent_id, req.target),
         true <- not private_control_fields?(data),
         true <- byte_size(Jason.encode!(data)) <= 131_584 do
      push({type, data}, state)
    else
      _ -> push({:error, :conversation_unavailable}, state)
    end
  rescue
    _ -> push({:error, :conversation_unavailable}, state)
  end

  defp publish_control({:error, reason}, _type, _req, state), do: push({:error, reason}, state)

  defp publish_control(_, _type, _req, state),
    do: push({:error, :conversation_unavailable}, state)

  defp correlated_control?(%{operation: :activity}, %{commands: commands})
       when is_list(commands) do
    length(commands) <= 50 and
      Enum.all?(commands, &(is_map(&1) and control_command_id?(&1[:command_id]))) and
      length(Enum.uniq_by(commands, & &1.command_id)) == length(commands)
  end

  defp correlated_control?(%{operation: :cancel, input: id}, %{command_id: id}), do: true

  defp correlated_control?(%{operation: :interactions, input: id}, %{
         command_id: id,
         interactions: prompts
       })
       when is_list(prompts) do
    length(prompts) <= 50 and
      Enum.all?(
        prompts,
        &(is_map(&1) and &1[:command_id] == id and
            bounded_control_id?(&1[:request_id]) and bounded_control_id?(&1[:operation_id]) and
            &1[:revision] === 1)
      ) and
      length(Enum.uniq_by(prompts, & &1.request_id)) == length(prompts)
  end

  defp correlated_control?(%{operation: operation, input: input}, value)
       when operation in [:interaction_choice, :interaction_approval],
       do:
         Enum.all?(
           [:command_id, :request_id, :operation_id, :revision],
           &(Map.get(value, &1) === Map.fetch!(input, &1))
         )

  defp correlated_control?(_, _), do: false

  defp control_command_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp bounded_control_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)

  defp notice_page_fields?(page) do
    Enum.sort(Map.keys(page)) ==
      [
        :complete,
        :engagement_id,
        :has_older,
        :head,
        :next_before,
        :notices,
        :owner_id,
        :target_agent_id,
        :through
      ]
  end

  defp private_control_fields?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      key in [
        :signed_request,
        :session_token,
        :conversation_source,
        :receipt,
        :proof,
        "signed_request",
        "session_token",
        "conversation_source",
        "receipt",
        "proof"
      ] or
        private_control_fields?(value)
    end)
  end

  defp private_control_fields?(list) when is_list(list),
    do: Enum.any?(list, &private_control_fields?/1)

  defp private_control_fields?(_), do: false

  # The client fence is only an expected identity; it cannot choose a route.
  # The first history may carry a reconnect fence, verified by the host before
  # publication. Every subsequent operation must retain the pinned attachment.
  defp attached_scope(_request, %{agent_id: nil}), do: :ok

  defp attached_scope(request, state) do
    if request.target == state.agent_id and
         Keyword.get(request.opts, :expected_engagement_id) == state.engagement_id,
       do: :ok,
       else: {:error, :conversation_scope_changed}
  end

  defp proof_opts(%{session_token: proof} = req), do: [session_token: proof] ++ req.opts
  defp proof_opts(req), do: [signed_request: req.proof] ++ req.opts
  defp publish({:ok, value}, type, state), do: push({type, value}, state)
  defp publish({:error, reason}, _type, state), do: push({:error, reason}, state)

  # Public facade with existing Gateway-style runtime injection for isolated
  # boundary tests. No module is selectable by a client frame.
  defp call(function, args) do
    apply(Application.get_env(:arbor_gateway, :chat_agent_facade, Arbor.Agent), function, args)
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  @impl true
  def handle_info({:terminal_ping, tag}, %{keepalive: %{tag: tag, challenge: nil}} = state) do
    case session_binding(state) do
      {:ok, _} ->
        challenge = :crypto.strong_rand_bytes(16)
        latest = schedule_pong(%{state | keepalive: %{state.keepalive | challenge: challenge}})
        {:push, [{:ping, challenge}], latest}

      _ ->
        close_session(state, :unauthorized)
    end
  end

  def handle_info({:terminal_pong_timeout, tag}, %{keepalive: %{tag: tag}} = state),
    do: close_session(state, :keepalive_timeout)

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_control({payload, [opcode: :pong]}, %{keepalive: %{challenge: challenge}} = state)
      when is_binary(challenge) and payload == challenge do
    case session_binding(state) do
      {:ok, _} -> {:ok, schedule_ping(state)}
      _ -> close_session(state, :unauthorized)
    end
  end

  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    cancel_keepalive(state)
    retire_secret(Map.get(state, :credential_table))
    :ok
  end

  defp schedule_ping(state) do
    cancel_keepalive(state)

    options =
      case state.keepalive do
        nil -> keepalive_options()
        keepalive -> keepalive.options
      end

    tag = make_ref()
    timer = Process.send_after(self(), {:terminal_ping, tag}, options.interval_ms)
    %{state | keepalive: %{options: options, tag: tag, timer: timer, challenge: nil}}
  end

  defp schedule_pong(state) do
    cancel_keepalive(state)
    tag = make_ref()

    timer =
      Process.send_after(
        self(),
        {:terminal_pong_timeout, tag},
        state.keepalive.options.timeout_ms
      )

    %{state | keepalive: %{state.keepalive | tag: tag, timer: timer}}
  end

  # An RPC can occupy this callback while a timely pong and its old timer queue
  # behind it. Give that pong a processing window after dispatch, invalidating
  # the old generation; this does not retry or reinterpret the RPC result.
  defp rearm_pong_after_dispatch(%{keepalive: %{challenge: challenge}} = state)
       when is_binary(challenge), do: schedule_pong(state)

  defp rearm_pong_after_dispatch(state), do: state

  defp cancel_keepalive(%{keepalive: %{timer: timer}}), do: Process.cancel_timer(timer)
  defp cancel_keepalive(_), do: :ok

  defp close_session(state, reason) do
    cancel_keepalive(state)
    retire_secret(Map.get(state, :credential_table))

    closed =
      Map.merge(state, %{
        credential_table: nil,
        keepalive: nil,
        invalidated?: true,
        agent_id: nil,
        engagement_id: nil
      })

    if reason == :unauthorized,
      do: {:stop, :normal, 1008, [{:text, Protocol.encode({:error, :unauthorized})}], closed},
      else: {:stop, :normal, 1001, closed}
  end

  # A call can finish after logout or authority loss. Withhold ALL returned data, including
  # initial history and definitive-rejection envelopes, if authority was lost.
  # A submitted command may already have been admitted: this is an uncertain
  # outcome, never evidence that no effect happened.
  defp push(event, %{auth_mode: :conversation_session} = state) do
    case session_binding(state) do
      {:ok, _} ->
        raw_push(event, state)

      _ ->
        close_session(state, :unauthorized)
    end
  end

  defp push(event, state), do: raw_push(event, state)

  defp raw_push(
         {:error, :conversation_scope_changed} = event,
         %{auth_mode: :conversation_session} = state
       ) do
    {:stop, :normal, 1008, _messages, closed} = close_session(state, :unauthorized)
    {:stop, :normal, 1008, [{:text, Protocol.encode(event)}], closed}
  end

  defp raw_push({:error, :conversation_scope_changed} = event, state),
    do:
      {:push, [{:text, Protocol.encode(event)}],
       %{state | agent_id: nil, engagement_id: nil, invalidated?: true}}

  defp raw_push(event, state), do: {:push, [{:text, Protocol.encode(event)}], state}

  defp session_binding(state) do
    with [{:credential, credential}] <- :ets.lookup(state.credential_table, :credential),
         {:ok, binding} <- TerminalLogin.verify(credential),
         true <-
           Map.take(binding, @binding_keys) == Map.take(state, @binding_keys) do
      {:ok, binding}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  defp retire_secret(nil), do: :ok

  defp retire_secret(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
