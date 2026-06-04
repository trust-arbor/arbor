defmodule Arbor.Comms.InteractionRouterTest do
  @moduledoc """
  Tests for `Arbor.Comms.InteractionRouter` Phase 1.

  Verifies:
    * Non-blocking request flow — returns immediately with `request_id`
    * Registry persistence — pending interactions are queryable
    * Response routing — `respond/3` broadcasts on the per-agent topic
    * Adapter dispatch — when presence is registered, the adapter's
      `send_interaction/2` is called with the right channel meta
    * No-adapter path — interactions queue when no channel adapter
      is registered for the active channel
    * No-presence path — interactions queue when the user has no
      active presence
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Interaction

  # A dummy in-process adapter that records calls to a test pid.
  defmodule TestAdapter do
    @behaviour Arbor.Contracts.Comms.ChannelAdapter

    def send_interaction(channel_meta, %Interaction{} = interaction) do
      test_pid = Map.fetch!(channel_meta, :test_pid)
      send(test_pid, {:adapter_called, channel_meta, interaction})
      :ok
    end

    def parse_response(_raw), do: :not_interaction
    def channel_kind, do: :dashboard
  end

  defmodule CrashAdapter do
    @behaviour Arbor.Contracts.Comms.ChannelAdapter
    def send_interaction(_meta, _interaction), do: raise("kaboom")
    def parse_response(_raw), do: :not_interaction
    def channel_kind, do: :dashboard
  end

  setup_all do
    # PubSub MUST exist before the tracker can init (the tracker
    # subscribes to its registry on startup). Bootstrap in this order.
    pubsub = pubsub_server()
    ensure_started!(InteractionRegistry)
    ensure_started!({PresenceTracker, pubsub_server: pubsub})
    {:ok, pubsub: pubsub}
  end

  setup %{pubsub: pubsub} do
    InteractionRegistry.reset()
    Phoenix.PubSub.subscribe(pubsub, "interaction:agent:test_agent")
    :ok
  end

  describe "request/2 (non-blocking)" do
    test "returns {:ok, request_id} immediately", %{pubsub: _} do
      assert {:ok, request_id} =
               InteractionRouter.request(
                 %{
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: "test_user_no_presence",
                   description: "Run mix test?"
                 },
                 adapter_map: %{}
               )

      assert is_binary(request_id)
      assert String.starts_with?(request_id, "irq_")
    end

    test "respects caller-provided request_id (idempotency hook)" do
      assert {:ok, "irq_custom_abc123"} =
               InteractionRouter.request(
                 %{
                   request_id: "irq_custom_abc123",
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: "no_presence_user",
                   description: "x"
                 },
                 adapter_map: %{}
               )
    end

    test "persists the interaction in the registry" do
      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "Approve?"
          },
          adapter_map: %{}
        )

      assert {:ok, %Interaction{} = persisted} = InteractionRegistry.get(request_id)
      assert persisted.kind == :approval
      assert persisted.description == "Approve?"
      assert persisted.response_topic == "interaction:agent:test_agent"
    end

    test "missing agent_id rejected" do
      assert {:error, :agent_id_required} =
               InteractionRouter.request(%{description: "x"}, adapter_map: %{})
    end
  end

  describe "request/2 with active presence" do
    test "dispatches to the adapter registered for the active channel" do
      user_id = "user_with_presence_#{System.unique_integer([:positive])}"

      # Track this test process's presence on the :dashboard channel.
      {:ok, _ref} =
        PresenceTracker.track(self(), user_id, :dashboard, %{test_pid: self()})

      # Phoenix.Tracker is gossip-based; wait for the registration to
      # land in the local presence list.
      assert_eventually(fn ->
        match?([{:dashboard, _}], PresenceTracker.active_channels(user_id))
      end)

      {:ok, _request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: user_id,
            description: "Run mix test?"
          },
          adapter_map: %{dashboard: TestAdapter}
        )

      assert_receive {:adapter_called, channel_meta, %Interaction{description: "Run mix test?"}},
                     1_000

      assert channel_meta.channel == :dashboard
      assert channel_meta.test_pid == self()
    end

    test "queues (returns :ok) when no adapter is registered for the active channel" do
      user_id = "user_no_adapter_#{System.unique_integer([:positive])}"
      {:ok, _ref} = PresenceTracker.track(self(), user_id, :dashboard, %{})

      assert_eventually(fn ->
        match?([{:dashboard, _}], PresenceTracker.active_channels(user_id))
      end)

      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: user_id,
            description: "x"
          },
          adapter_map: %{signal: TestAdapter}
        )

      # Still persisted, just nobody to deliver to right now
      assert {:ok, _} = InteractionRegistry.get(request_id)
    end

    test "adapter crashes don't crash the router" do
      user_id = "user_crash_#{System.unique_integer([:positive])}"
      {:ok, _ref} = PresenceTracker.track(self(), user_id, :dashboard, %{})

      assert_eventually(fn ->
        match?([{:dashboard, _}], PresenceTracker.active_channels(user_id))
      end)

      assert {:ok, _request_id} =
               InteractionRouter.request(
                 %{
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: user_id,
                   description: "x"
                 },
                 adapter_map: %{dashboard: CrashAdapter}
               )
    end
  end

  describe "respond/3" do
    test "broadcasts the response on the per-agent PubSub topic" do
      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "x"
          },
          adapter_map: %{}
        )

      assert :ok = InteractionRouter.respond(request_id, :approved, %{channel: :dashboard})

      assert_receive {:interaction_response,
                      %{
                        request_id: ^request_id,
                        response: :approved,
                        metadata: %{channel: :dashboard}
                      }},
                     1_000
    end

    test "removes the interaction from the pending set after responding" do
      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "x"
          },
          adapter_map: %{}
        )

      assert {:ok, _} = InteractionRegistry.get(request_id)
      :ok = InteractionRouter.respond(request_id, :approved)
      assert :not_found = InteractionRegistry.get(request_id)
    end

    test "responding to an unknown request_id returns {:error, :not_found}" do
      assert {:error, :not_found} = InteractionRouter.respond("irq_nonexistent", :approved)
    end
  end

  ## Helpers

  defp ensure_started!({mod, opts}) do
    case mod.start_link(opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_started!(mod) do
    case mod.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp pubsub_server do
    cond do
      Process.whereis(Arbor.Dashboard.PubSub) -> Arbor.Dashboard.PubSub
      Process.whereis(Arbor.Web.PubSub) -> Arbor.Web.PubSub
      Process.whereis(Arbor.Comms.PubSub) -> Arbor.Comms.PubSub
      true -> start_test_pubsub()
    end
  end

  defp start_test_pubsub do
    # Start under one of the names the router's current_pubsub/0
    # discovery list looks for — that way response broadcasts are
    # routable in test without extra wiring.
    name = Arbor.Comms.PubSub

    case Supervisor.start_link(
           [{Phoenix.PubSub, name: name}],
           strategy: :one_for_one,
           name: :"#{name}.RootSup"
         ) do
      {:ok, _} -> name
      {:error, {:already_started, _}} -> name
    end
  end

  # Phoenix.Tracker is gossip-based; presence updates propagate
  # asynchronously. Poll briefly for the condition.
  defp assert_eventually(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("Condition not met within timeout")
      else
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      end
    end
  end
end
