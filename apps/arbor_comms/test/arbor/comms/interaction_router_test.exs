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

  describe "audit signals" do
    setup do
      ensure_signals!()
      :ok
    end

    test "correlates requested/queued/resolved to exact task_id without sensitive metadata" do
      task_id = "coding-benchmark-legacy-#{System.unique_integer([:positive])}"
      secret_note = "operator secret note #{System.unique_integer([:positive])}"
      secret_cmd = "rm -rf /tmp/sensitive-#{System.unique_integer([:positive])}"

      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "Approve shell?",
            metadata: %{
              "task_id" => "ignored_top_level_when_provenance_present",
              "approval_context" => %{
                "target" => secret_cmd,
                "params" => %{"command" => secret_cmd},
                "payload_preview" => secret_cmd,
                "provenance" => %{"task_id" => task_id}
              },
              "provenance" => %{"task_id" => task_id},
              "target" => secret_cmd,
              "payload_preview" => secret_cmd
            }
          },
          adapter_map: %{}
        )

      assert :ok =
               InteractionRouter.respond(request_id, :approved, %{
                 channel: :dashboard,
                 note: secret_note,
                 decision: :approved
               })

      assert {:ok, signals} =
               Arbor.Signals.query(category: :interaction, correlation_id: task_id, limit: 20)

      assert length(signals) >= 2
      types = signals |> Enum.map(& &1.type) |> Enum.sort()
      assert :queued in types or :requested in types
      assert :resolved in types

      for signal <- signals do
        assert signal.correlation_id == task_id
        assert signal.data.request_id == request_id
        assert signal.data.kind == :approval
        refute Map.has_key?(signal.data, :approval_context)
        refute Map.has_key?(signal.data, "approval_context")
        refute Map.has_key?(signal.data, :target)
        refute Map.has_key?(signal.data, :params)
        refute Map.has_key?(signal.data, :payload_preview)
        refute Map.has_key?(signal.data, :metadata)
        refute Map.has_key?(signal.data, :note)
        refute inspect(signal.data) =~ secret_note
        refute inspect(signal.data) =~ secret_cmd
      end

      assert {:ok, other} =
               Arbor.Signals.query(
                 category: :interaction,
                 correlation_id: "other-task-#{System.unique_integer([:positive])}",
                 limit: 20
               )

      assert other == []
    end

    test "accepts atom provenance.task_id and string-key metadata forms" do
      task_id = "task_atom_#{System.unique_integer([:positive])}"

      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :approval,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "x",
            metadata: %{
              provenance: %{task_id: task_id}
            }
          },
          adapter_map: %{}
        )

      assert {:ok, signals} =
               Arbor.Signals.query(category: :interaction, correlation_id: task_id, limit: 10)

      assert Enum.any?(signals, &(&1.data.request_id == request_id))
    end

    test "does not copy free-form interaction responses into audit signals" do
      task_id = "task_text_#{System.unique_integer([:positive])}"
      secret = "private response #{System.unique_integer([:positive])}"

      {:ok, request_id} =
        InteractionRouter.request(
          %{
            kind: :clarification,
            agent_id: "test_agent",
            user_id: "no_presence_user",
            description: "x",
            metadata: %{provenance: %{task_id: task_id}}
          },
          adapter_map: %{}
        )

      assert :ok = InteractionRouter.respond(request_id, {:text, secret})

      assert {:ok, signals} =
               Arbor.Signals.query(category: :interaction, correlation_id: task_id, limit: 10)

      assert Enum.any?(signals, &(&1.type == :resolved))
      refute Enum.any?(signals, &(inspect(&1.data) =~ secret))
      refute Enum.any?(signals, &Map.has_key?(&1.data, :response))
    end

    test "does not normalize malformed provenance into another task's correlation id" do
      task_id = "task_exact_#{System.unique_integer([:positive])}"

      assert {:ok, _request_id} =
               InteractionRouter.request(
                 %{
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: "no_presence_user",
                   description: "x",
                   metadata: %{provenance: %{task_id: " #{task_id} "}}
                 },
                 adapter_map: %{}
               )

      assert {:ok, []} =
               Arbor.Signals.query(category: :interaction, correlation_id: task_id, limit: 10)
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

    test "non-approval text is terminally responded without an approval decision" do
      assert {:ok, request_id} =
               InteractionRouter.request(
                 %{
                   kind: :clarification,
                   agent_id: "test_agent",
                   user_id: "no_presence_user",
                   description: "Which branch?"
                 },
                 adapter_map: %{}
               )

      assert :ok = InteractionRouter.respond(request_id, {:text, "main"})
      assert {:ok, terminal} = InteractionRegistry.get_terminal(request_id)
      assert terminal.status == :responded
      assert terminal.decision == nil
      assert terminal.response == {:text, "main"}
    end
  end

  describe "await_response/3 terminal lifecycle" do
    test "immediate retained response still wins before the waiter subscribes" do
      assert {:ok, request_id} =
               InteractionRouter.request(
                 %{
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: "no_presence_user",
                   description: "Approve immediately?"
                 },
                 adapter_map: %{}
               )

      assert :ok = InteractionRouter.respond(request_id, :approved, %{decision: :approve})

      assert {:ok, :approved, %{decision: :approve}} =
               InteractionRouter.await_response(request_id, "test_agent", timeout: 5)
    end

    test "security regression: timeout abandons and rejects every late approval" do
      assert {:ok, request_id} =
               InteractionRouter.request(
                 %{
                   kind: :approval,
                   agent_id: "test_agent",
                   user_id: "no_presence_user",
                   description: "Approve before timeout?"
                 },
                 adapter_map: %{}
               )

      assert {:error, :timeout} =
               InteractionRouter.await_response(request_id, "test_agent", timeout: 5)

      refute Enum.any?(InteractionRouter.pending(), &(&1.request_id == request_id))
      assert {:ok, terminal} = InteractionRegistry.get_terminal(request_id)
      assert terminal.status == :abandoned
      assert terminal.reason == :await_timeout
      assert :not_found = InteractionRouter.get_response(request_id)

      assert {:error, {:already_terminal, :abandoned}} =
               InteractionRouter.respond(request_id, :approved, %{decision: :approve})

      assert :not_found = InteractionRouter.get_response(request_id)
      assert {:ok, terminal_after_late_response} = InteractionRegistry.get_terminal(request_id)
      assert terminal_after_late_response.status == :abandoned
      assert terminal_after_late_response.response == nil

      assert :ok = Arbor.Comms.abandon_interaction(request_id, :await_timeout)
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

  defp ensure_signals! do
    Application.ensure_all_started(:arbor_signals)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {mod, _} = child
          _ = Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
          _ = Supervisor.start_child(Arbor.Signals.Supervisor, child)
          :ok

        {:error, _reason} ->
          :ok
      end
    end

    true = Arbor.Signals.healthy?()
  end
end
