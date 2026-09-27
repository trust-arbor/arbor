defmodule Arbor.Gateway.Chat.Socket do
  @moduledoc """
  Authenticated conversation transport. The upgrade identifies the socket; every
  operation carries a fresh, operation-bound signature consumed once by Agent.

  History and command-journal pages have independent cursors. No agent-wide
  signal is a private transcript, and no socket attachment grants capabilities.
  Legacy server slash commands, cancellation and approvals remain unavailable
  until their own authenticated operation contracts are implemented.
  """
  @behaviour WebSock
  alias Arbor.Gateway.Chat.Protocol

  @impl true
  def init(state),
    do: {:ok, Map.merge(%{agent_id: nil, engagement_id: nil, invalidated?: false}, state)}

  @impl true
  def handle_in(_frame, %{invalidated?: true} = state),
    do: push({:error, :conversation_scope_changed}, state)

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

  # A fresh read is also the attachment operation. The host chooses the private
  # engagement from authenticated ownership, never from a client routing field.
  defp dispatch(%{operation: :history} = req, state) do
    case call(:conversation_history, [state.principal, req.target, proof_opts(req)]) do
      {:ok, page} ->
        push({:conversation_history, Map.put(page, :agent_id, req.target)}, %{
          state
          | agent_id: req.target,
            engagement_id: page.engagement_id
        })

      {:error, reason} ->
        push({:error, reason}, state)
    end
  end

  defp dispatch(%{target: target}, %{agent_id: attached} = state) when target != attached,
    do: push({:error, :not_attached}, state)

  defp dispatch(%{operation: :submit, input: %{text: "/" <> _}} = _req, state),
    do: push({:error, :server_commands_unavailable}, state)

  defp dispatch(%{operation: :submit} = req, state) do
    result =
      call(:submit_conversation_command, [state.principal, req.target, req.input, proof_opts(req)])

    case result do
      {:error, reason}
      when reason in [:unsupported_conversation_capability, :invalid_command, :command_conflict] ->
        push({:conversation_rejected, %{id: req.input.id, reason: reason}}, state)

      _ ->
        publish(result, :conversation_command, state)
    end
  end

  defp dispatch(%{operation: :command} = req, state) do
    result =
      call(:conversation_command, [state.principal, req.target, req.input, proof_opts(req)])

    publish(result, :conversation_command, state)
  end

  defp dispatch(%{operation: :events} = req, state) do
    result = call(:conversation_events, [state.principal, req.target, req.input, proof_opts(req)])
    publish(result, :conversation_events, state)
  end

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
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp push({:error, :conversation_scope_changed} = event, state),
    do:
      {:push, [{:text, Protocol.encode(event)}],
       %{state | agent_id: nil, engagement_id: nil, invalidated?: true}}

  defp push(event, state), do: {:push, [{:text, Protocol.encode(event)}], state}
end
