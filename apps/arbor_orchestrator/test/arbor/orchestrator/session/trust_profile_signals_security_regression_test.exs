defmodule Arbor.Orchestrator.Session.TrustProfileSignalsSecurityRegressionTest do
  @moduledoc """
  Security regression: a session must hear trust profile changes and must not
  hide what it failed to do about them.

  Until 2026-11-21 `Session` subscribed with a map where the signal bus
  requires a handler function. The call raised, a `rescue` swallowed it, and
  no session ever received a profile change.

  Until 2026-11-22 the handler then (a) listened for updates only, so a deleted
  or disabled profile never reached it, (b) kept every tool the agent had
  discovered under the old profile visible, and (c) discarded the result of the
  capability revocation, which the security kernel refuses for an ordinary
  agent (`arbor://security/revoke/scope` is required). The session looked as
  if it revoked and did nothing.

  Enforcement of a tightened profile does not rest on this handler:
  `Arbor.Trust.authorize/4` applies the current profile on every call. Stale
  capabilities in the store are a separate, open item
  (`.arbor/roadmap/0-inbox/trust-profile-change-stale-capabilities.md`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.TrustProfileSignals

  @moduletag :fast
  @moduletag :security_regression

  @telemetry [:arbor, :session, :profile_change_revocation, :failed]

  describe "delivery" do
    test "security regression: every trust profile broadcast reaches the subscribed session process" do
      agent_id = "agent_profile_signal_#{System.unique_integer([:positive])}"

      assert {:ok, subscription_ids} = TrustProfileSignals.subscribe()
      assert length(subscription_ids) == length(TrustProfileSignals.types())
      on_exit(fn -> Enum.each(subscription_ids, &Arbor.Signals.unsubscribe/1) end)

      for type <- [:profile_updated, :profile_deleted, :profile_disabled] do
        Arbor.Signals.emit(:trust, type, %{agent_id: agent_id, origin_node: node()})

        # The same pattern as the Session.handle_info/2 clause.
        assert_receive {:signal_received,
                        %{category: :trust, type: ^type, data: %{agent_id: ^agent_id}}},
                       1_000
      end
    end

    test "the session source subscribes through this module with no silent rescue" do
      source =
        File.read!(Path.expand("../../../../lib/arbor/orchestrator/session.ex", __DIR__))

      assert source =~ "TrustProfileSignals.subscribe()"
      refute source =~ ~s|Arbor.Signals.subscribe("trust.profile_updated", %{|
    end
  end

  describe "Session.handle_info/2 on a profile change" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        @telemetry,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:revocation_failed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %Session{
        session_id: "session_profile_change_#{System.unique_integer([:positive])}",
        agent_id: "agent_profile_change_#{System.unique_integer([:positive])}",
        discovered_tools: MapSet.new(["shell_execute", "file_write"])
      }

      {:ok, state: state}
    end

    for type <- [:profile_updated, :profile_changed, :profile_deleted, :profile_disabled] do
      test "security regression: #{type} drops the tools discovered under the old profile",
           %{state: state} do
        signal = signal(unquote(type), state.agent_id)

        capture_log(fn ->
          assert {:noreply, new_state} = Session.handle_info({:signal_received, signal}, state)
          assert new_state.discovered_tools == MapSet.new()
          send(self(), {:new_state, new_state})
        end)

        assert_received {:new_state, new_state}
        assert %{new_state | discovered_tools: state.discovered_tools} == state
      end
    end

    test "security regression: a refused revocation is reported, not swallowed", %{state: state} do
      session_id = state.session_id

      log =
        capture_log(fn ->
          assert {:noreply, _state} =
                   Session.handle_info(
                     {:signal_received, signal(:profile_updated, state.agent_id)},
                     state
                   )
        end)

      # This process holds no signing authority, the same end state as an agent
      # whose authority lacks the scope-revocation right.
      assert_received {:revocation_failed, %{count: 1},
                       %{session_id: ^session_id, type: :profile_updated, reason: :no_authority}}

      assert log =~ "session capabilities not revoked after trust profile_updated"
    end

    test "another agent's profile change leaves the session untouched", %{state: state} do
      signal = signal(:profile_deleted, "agent_someone_else")

      assert {:noreply, ^state} = Session.handle_info({:signal_received, signal}, state)
      refute_received {:revocation_failed, _measurements, _metadata}
    end
  end

  defp signal(type, agent_id) do
    %{category: :trust, type: type, data: %{agent_id: agent_id, origin_node: node()}}
  end
end
