defmodule Arbor.Comms.InteractionRegistryTest do
  @moduledoc """
  Tests for `Arbor.Comms.InteractionRegistry`.

  Covers the `list_pending_for_user/1` accessor added 2026-06-06 for
  the Signal adapter's partial-response resolution path. (Other
  registry behaviour — put/get/resolve — is covered indirectly by
  `interaction_router_test.exs`.)
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Comms.InteractionRegistry.Routing
  alias Arbor.Contracts.Comms.Interaction

  setup do
    if Process.whereis(InteractionRegistry) == nil do
      start_supervised!(InteractionRegistry)
    end

    InteractionRegistry.reset()
    :ok
  end

  describe "authoritative terminal lifecycle" do
    test "security regression: resolve vs abandon has exactly one serialized winner" do
      for iteration <- 1..20 do
        {:ok, interaction} = put_for("alice", "race #{iteration}")
        parent = self()

        responder =
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            InteractionRegistry.resolve(interaction.request_id,
              response: :approved,
              metadata: %{decision: :approve}
            )
          end)

        abandoner =
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            InteractionRegistry.abandon(interaction.request_id, :owner_timeout)
          end)

        assert_receive {:ready, responder_pid}
        assert_receive {:ready, abandoner_pid}
        send(responder_pid, :go)
        send(abandoner_pid, :go)

        response_result = Task.await(responder)
        abandon_result = Task.await(abandoner)

        winners =
          Enum.count([response_result, abandon_result], fn
            {:ok, %Interaction{}} -> true
            _ -> false
          end)

        assert winners == 1
        assert :not_found = InteractionRegistry.get(interaction.request_id)

        refute Enum.any?(
                 InteractionRegistry.list_pending(),
                 &(&1.request_id == interaction.request_id)
               )

        assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)

        case terminal.status do
          :responded ->
            assert response_result == {:ok, interaction}
            assert abandon_result == {:error, {:already_terminal, :responded}}
            assert terminal.decision == :approved
            assert terminal.response == :approved

          :abandoned ->
            assert abandon_result == {:ok, interaction}
            assert response_result == {:error, {:already_terminal, :abandoned}}
            assert terminal.reason == :owner_timeout
            assert terminal.decision == nil
            assert terminal.response == nil
        end
      end
    end

    test "security regression: abandonment is idempotent and rejects late approval" do
      {:ok, interaction} = put_for("alice", "late approval")

      assert {:ok, ^interaction} =
               InteractionRegistry.abandon(interaction.request_id, :await_timeout)

      assert {:ok, :already_abandoned} =
               InteractionRegistry.abandon(interaction.request_id, :await_timeout)

      assert {:error, {:already_terminal, :abandoned}} =
               InteractionRegistry.resolve(interaction.request_id,
                 response: :approved,
                 metadata: %{decision: :approve}
               )

      assert :not_found = InteractionRegistry.get(interaction.request_id)
      assert :not_found = InteractionRegistry.get_resolved(interaction.request_id)
      assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
      assert terminal.status == :abandoned
      assert terminal.reason == :await_timeout
      assert terminal.response == nil
      assert terminal.decision == nil
    end

    test "security regression: expiry wins before a late approval" do
      {:ok, interaction} =
        Interaction.new(%{
          kind: :approval,
          agent_id: "agent_expired",
          user_id: "alice",
          description: "already expired",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      assert {:ok, ^interaction} = InteractionRegistry.put(interaction)

      assert {:error, {:already_terminal, :expired}} =
               InteractionRegistry.resolve(interaction.request_id,
                 response: :approved,
                 metadata: %{decision: :approve}
               )

      assert :not_found = InteractionRegistry.get(interaction.request_id)

      refute Enum.any?(
               InteractionRegistry.list_pending(),
               &(&1.request_id == interaction.request_id)
             )

      assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)
      assert terminal.status == :expired
      assert terminal.response == nil
      assert terminal.decision == nil
    end

    test "security regression: armed owner deadline rejects a late approval" do
      {:ok, interaction} = put_for("alice", "armed timeout")

      assert {:ok, capture, {:terminal, terminal}} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 0)

      assert capture.authority_node == node()
      assert capture.authority_pid == Process.whereis(Authority)
      assert capture.request_id == interaction.request_id
      assert terminal.status == :abandoned
      assert terminal.reason == :await_timeout

      assert {:error, {:already_terminal, :abandoned}} =
               InteractionRegistry.resolve(interaction.request_id,
                 response: :approved,
                 metadata: %{decision: :approve}
               )
    end

    test "owner deadline cannot be extended and timeout captures cannot be rebound" do
      {:ok, interaction} = put_for("alice", "non-extendable timeout")

      assert {:ok, first_capture, :armed} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 60_000)

      first_deadline =
        :sys.get_state(Authority).entries[interaction.request_id].owner_deadline

      assert {:ok, second_capture, :armed} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 120_000)

      assert second_capture.authority_pid == first_capture.authority_pid

      assert :sys.get_state(Authority).entries[interaction.request_id].owner_deadline ==
               first_deadline

      assert {:error, :invalid_timeout_capture} =
               InteractionRegistry.finalize_timeout(first_capture, "irq_different")

      assert {:ok, %{status: :abandoned}} =
               InteractionRegistry.finalize_timeout(first_capture, interaction.request_id)
    end

    test "security regression: response and timeout finalization have one authority winner" do
      {:ok, interaction} = put_for("alice", "timeout race")

      assert {:ok, capture, :armed} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 60_000)

      parent = self()

      responder =
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              InteractionRegistry.resolve(interaction.request_id,
                response: :approved,
                metadata: %{decision: :approve}
              )
          end
        end)

      timer =
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> InteractionRegistry.finalize_timeout(capture, interaction.request_id)
          end
        end)

      assert_receive {:ready, responder_pid}
      assert_receive {:ready, timer_pid}
      send(responder_pid, :go)
      send(timer_pid, :go)

      response_result = Task.await(responder)
      timeout_result = Task.await(timer)

      assert {:ok, terminal} = InteractionRegistry.get_terminal(interaction.request_id)

      case terminal.status do
        :responded ->
          assert response_result == {:ok, interaction}
          assert {:ok, %{status: :responded, response: :approved}} = timeout_result

        :abandoned ->
          assert response_result == {:error, {:already_terminal, :abandoned}}
          assert {:ok, %{status: :abandoned}} = timeout_result
      end
    end

    test "timeout finalization uses the captured authority after Tracker discovery disappears" do
      {:ok, interaction} = put_for("alice", "captured authority")

      assert {:ok, capture, :armed} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 60_000)

      authority = Process.whereis(Authority)

      assert :ok =
               Phoenix.Tracker.untrack(
                 InteractionRegistry,
                 authority,
                 "interactions",
                 interaction.request_id
               )

      assert {:ok, %{status: :abandoned, authority_node: authority_node}} =
               InteractionRegistry.finalize_timeout(capture, interaction.request_id)

      assert authority_node == node()
    end

    test "security regression: authority crash loses pending state and fails late response closed" do
      {:ok, interaction} = put_for("alice", "must not resurrect")

      assert {:ok, capture, :armed} =
               InteractionRegistry.capture_timeout_authority(interaction.request_id, 60_000)

      old_authority = Process.whereis(Authority)
      old_tracker = Process.whereis(InteractionRegistry)

      assert is_pid(old_authority)
      assert is_pid(old_tracker)
      assert {:ok, ^interaction} = InteractionRegistry.get(interaction.request_id)

      Process.exit(old_authority, :kill)

      assert_eventually(fn ->
        new_authority = Process.whereis(Authority)
        new_tracker = Process.whereis(InteractionRegistry)

        is_pid(new_authority) and new_authority != old_authority and
          is_pid(new_tracker) and new_tracker != old_tracker
      end)

      assert :not_found = InteractionRegistry.get(interaction.request_id)

      refute Enum.any?(
               InteractionRegistry.list_pending(),
               &(&1.request_id == interaction.request_id)
             )

      assert :not_found =
               InteractionRegistry.resolve(interaction.request_id,
                 response: :approved,
                 metadata: %{decision: :approve}
               )

      assert :not_found = InteractionRegistry.get_resolved(interaction.request_id)
      assert :not_found = InteractionRegistry.get_terminal(interaction.request_id)

      assert {:error, :authority_unavailable} =
               InteractionRegistry.finalize_timeout(capture, interaction.request_id)
    end

    test "peer transition routing calls only the stamped remote authority" do
      assert {:local, Authority} = Routing.transition_target(:origin@host, :origin@host)

      assert {:remote, :origin@host, Authority} =
               Routing.transition_target(:origin@host, :peer@host)

      assert {:error, :invalid_authority} = Routing.transition_target("origin@host", :peer@host)

      remote_call = fn remote_node, module, function, args, timeout ->
        send(self(), {:remote_call, remote_node, module, function, args, timeout})
        :remote_result
      end

      assert :remote_result =
               Routing.dispatch(:origin@host, :abandon, ["irq_peer", :owner_timeout],
                 local_node: :peer@host,
                 timeout: 321,
                 remote_call: remote_call
               )

      assert_received {:remote_call, :origin@host, Authority, :abandon,
                       ["irq_peer", :owner_timeout], 321}

      assert {:error, :authority_unavailable} =
               Routing.dispatch(:offline@host, :respond, ["irq_peer", :approved, %{}],
                 local_node: :peer@host,
                 remote_call: fn _, _, _, _, _ -> {:badrpc, :nodedown} end
               )
    end
  end

  describe "list_pending_for_user/1" do
    test "returns empty list for a user with no pending interactions" do
      assert [] = InteractionRegistry.list_pending_for_user("nobody")
    end

    test "filters by user_id" do
      {:ok, a} = put_for("alice", "first")
      {:ok, _b} = put_for("bob", "second")

      assert [^a] = InteractionRegistry.list_pending_for_user("alice")
    end

    test "sorts newest first" do
      {:ok, older} = put_for("alice", "old", DateTime.add(DateTime.utc_now(), -10, :second))
      {:ok, newer} = put_for("alice", "new", DateTime.utc_now())

      assert [^newer, ^older] = InteractionRegistry.list_pending_for_user("alice")
    end

    test "doesn't return resolved interactions" do
      {:ok, a} = put_for("alice", "first")
      assert [^a] = InteractionRegistry.list_pending_for_user("alice")

      {:ok, ^a} = InteractionRegistry.resolve(a.request_id)
      assert [] = InteractionRegistry.list_pending_for_user("alice")
    end
  end

  defp put_for(user_id, description, submitted_at \\ nil) do
    submitted_at = submitted_at || DateTime.utc_now()

    {:ok, interaction} =
      Interaction.new(%{
        kind: :approval,
        agent_id: "agent_test_#{:erlang.unique_integer([:positive])}",
        user_id: user_id,
        description: description,
        submitted_at: submitted_at
      })

    InteractionRegistry.put(interaction)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
