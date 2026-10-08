defmodule Arbor.Dashboard.Live.ChatLive.GroupChatStartSecurityRegressionTest do
  @moduledoc """
  Starting the stopped members of a new group (decision 2026-10-08 D3) needs
  the signed-in human's session. `GroupChat.handle_event/3` is the narrowest
  public seam: ChatLive itself currently refuses every group event before
  dispatching here (see `ChatLiveTest`), so this exercises the helper the
  group UI uses directly, with the socket assigns Nav sets.

  The positive path (a valid session with the exact start capability starts
  the agent) is covered through the same facade by
  `Arbor.Agent.AuthorizeStartSecurityRegressionTest`; here we check that the
  dashboard passes exactly the session's actor and token, and nothing else.
  """
  use ExUnit.Case, async: false

  alias Arbor.Dashboard.Live.ChatLive.GroupChat

  @moduletag :fast
  @moduletag :security_regression

  @stopped_agent "agent_groupchat_start_probe"
  # Every way the group helper could start an agent or create the channel.
  @watched [
    {Arbor.Agent, :authorize_start, 3},
    {Arbor.Agent.Manager, :resume_agent, 1},
    {Arbor.Agent.Manager, :resume_agent, 2},
    {Arbor.Agent.Manager, :start_or_resume, 3},
    {Arbor.Agent.Lifecycle, :start, 2},
    {Arbor.Agent.Manager, :create_channel, 2}
  ]

  setup do
    if Process.whereis(Arbor.Agent.Registry) == nil,
      do: start_supervised!(Arbor.Agent.Registry)

    refute Arbor.Agent.running?(@stopped_agent)
    :ok
  end

  test "security regression: without a signed-in session no stopped agent is started" do
    for {actor, token} <- [
          {nil, nil},
          {"human_groupchat_probe", nil},
          {nil, "token"},
          {"human_groupchat_probe", ""}
        ] do
      {result, calls} = confirm_create_group(actor, token)

      assert calls == []
      assert {:noreply, socket} = result
      assert socket.assigns.error =~ "Sign in to the dashboard to start them"
      refute socket.assigns[:group_mode]
    end
  end

  test "security regression: with a session, starting goes only through authorize_start with that session" do
    actor = "human_groupchat_probe"
    token = "not-a-valid-session-token"

    {result, calls} = confirm_create_group(actor, token)

    assert calls == [
             {Arbor.Agent, :authorize_start, [actor, @stopped_agent, [session_token: token]]}
           ]

    # An invalid session is refused by the facade: nothing starts and no
    # channel is created with a stopped member.
    assert {:noreply, socket} = result
    assert socket.assigns.error == "Starting agent #{@stopped_agent} was refused."
    refute socket.assigns[:group_mode]
  end

  defp confirm_create_group(actor, token) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_agent_id: actor,
        session_token: token,
        group_selection: %{@stopped_agent => true},
        group_name_input: "Group Chat",
        group_mode: false
      }
    }

    observe(fn -> GroupChat.handle_event("confirm-create-group", %{}, socket) end)
  end

  # A process cannot trace its own calls, so the event runs in a worker. An
  # exception there is returned as the result, so the effect calls made before
  # it are still reported.
  defp observe(fun) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            result =
              try do
                fun.()
              rescue
                exception -> {:raised, exception}
              end

            send(parent, {:group_chat_result, self(), result})
        end
      end)

    watched = Enum.filter(@watched, &exported?/1)

    try do
      # A pattern only applies to a loaded module; a lazily loaded one would go
      # untraced and the refutations below would pass vacuously.
      for mfa <- watched, do: 1 = :erlang.trace_pattern(mfa, true, [:global])
      1 = :erlang.trace(worker, true, [:call])
      send(worker, :run)

      result =
        receive do
          {:group_chat_result, ^worker, result} ->
            result

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            flunk("worker failed: #{inspect(reason)}")
        after
          15_000 -> flunk("group chat event did not return")
        end

      barrier = :erlang.trace_delivered(worker)

      receive do
        {:trace_delivered, ^worker, ^barrier} -> :ok
      after
        5_000 -> flunk("trace messages were not delivered")
      end

      {result, drain(worker, [])}
    after
      for mfa <- watched, do: :erlang.trace_pattern(mfa, false, [:global])
    end
  end

  defp exported?({module, function, arity}) do
    Code.ensure_loaded!(module)
    function_exported?(module, function, arity)
  end

  defp drain(worker, calls) do
    receive do
      {:trace, ^worker, :call, {module, function, args}} ->
        drain(worker, [{module, function, args} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
