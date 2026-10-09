defmodule Arbor.Commands.Journeys.J0AuthenticatedPersonalAgentBaselineTest do
  @moduledoc """
  SU-0/J0 first authenticated personal-agent journey — measurement baseline.

  Exact owner commands (this worker did not execute them):

      ./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_baseline_helpers_test.exs

      ./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_personal_agent_baseline_test.exs --include database --include sqlite --include integration

  Independently asserted boundaries: auth, reply, persistence pair, index,
  no generic Memory.recall on authenticated turns, untouched control, outbound
  denial. See the companion Markdown in this directory for blocked
  production-path assertions.

  Does not replace production turn.dot, does not seed Memory.index, does not
  catch Engine/turn failures, and does not boot this topology from test_helper.
  """

  use ExUnit.Case, async: false

  alias Arbor.Commands.J0AuthenticatedBaseline
  alias Arbor.Commands.J0AuthenticatedBaseline.{SqliteEvidence, TraceHub}
  alias Arbor.LLM.Request
  alias Arbor.Orchestrator.Config, as: OrchestratorConfig

  @moduletag :integration
  @moduletag :database
  @moduletag :sqlite
  @moduletag timeout: 120_000

  setup_all do
    # start_suite!/0 registers the single suite-owner cleanup. Do not add a
    # second on_exit here: that would restore env/client twice and could
    # release resources this file did not create.
    state = J0AuthenticatedBaseline.start_suite!()
    {:ok, suite: state}
  end

  setup %{suite: suite} do
    case_ctx = J0AuthenticatedBaseline.start_case!(self())
    {:ok, Map.merge(suite, case_ctx)}
  end

  describe "green liveness, control, and closed outbound" do
    test "authenticated preference turn uses production turn.dot, captures the provider request, and returns the public reply",
         ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      conversant_id = ctx.conversant.id
      owner_id = ctx.owner.id

      refute conversant_id == owner_id
      refute J0AuthenticatedBaseline.mock_turn_dot?()

      result =
        J0AuthenticatedBaseline.send_authenticated!(
          conversant_id,
          conversationalist_id,
          J0AuthenticatedBaseline.preference()
        )

      assert {:ok, reply} = result
      assert is_binary(reply)
      assert reply == J0AuthenticatedBaseline.preference_reply()

      J0AuthenticatedBaseline.assert_committed_pair_now!(
        J0AuthenticatedBaseline.session_id!(conversationalist_id),
        J0AuthenticatedBaseline.engagement_id!(conversationalist_id, conversant_id),
        J0AuthenticatedBaseline.preference(),
        J0AuthenticatedBaseline.preference_reply()
      )

      request = J0AuthenticatedBaseline.await_provider_request!()
      assert %Request{} = request
      assert request.provider == J0AuthenticatedBaseline.capture_provider()
      transcript = J0AuthenticatedBaseline.request_transcript(request)
      assert transcript =~ J0AuthenticatedBaseline.preference_marker()

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end

    test "untouched control conversationalist does not receive the preference", ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      control_id = ctx.control.agent_id
      conversant_id = ctx.conversant.id

      assert {:ok, _reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 J0AuthenticatedBaseline.preference()
               )

      _ = J0AuthenticatedBaseline.await_provider_request!()
      _ = J0AuthenticatedBaseline.drain_provider_requests()

      assert {:ok, control_reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 control_id,
                 J0AuthenticatedBaseline.follow_up()
               )

      assert is_binary(control_reply)
      assert control_reply == J0AuthenticatedBaseline.follow_up_reply()

      control_request = J0AuthenticatedBaseline.await_provider_request!()
      control_transcript = J0AuthenticatedBaseline.request_transcript(control_request)
      assert control_transcript =~ J0AuthenticatedBaseline.follow_up()
      refute control_transcript =~ J0AuthenticatedBaseline.preference_marker()

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end

    test "unexpected cloud provider is denied without ReqLLM or ACP escape", ctx do
      result = J0AuthenticatedBaseline.complete_unexpected_provider!(ctx.client)
      assert {:error, :outbound_denied} = result

      assert_receive {:j0_outbound_denied, "openai", "gpt-4o", %Request{}}, 1_000
      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end
  end

  describe "durable sqlite conversation evidence" do
    test "polls a committed user/assistant pair scoped to the test engagement", ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      control_id = ctx.control.agent_id
      conversant_id = ctx.conversant.id

      assert {:ok, reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 J0AuthenticatedBaseline.preference()
               )

      assert is_binary(reply)
      _ = J0AuthenticatedBaseline.await_provider_request!()

      assert {:ok, _control_reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 control_id,
                 "hello control"
               )

      _ = J0AuthenticatedBaseline.drain_provider_requests()

      engagement_id =
        J0AuthenticatedBaseline.engagement_id!(conversationalist_id, conversant_id)

      session_id = J0AuthenticatedBaseline.session_id!(conversationalist_id)

      pair =
        SqliteEvidence.await_committed_pair!(
          session_id,
          engagement_id,
          J0AuthenticatedBaseline.preference_marker()
        )

      assert Enum.any?(pair, fn {role, text} ->
               role in [:user, "user"] and
                 String.contains?(text, J0AuthenticatedBaseline.preference_marker())
             end)

      assert Enum.any?(pair, fn {role, text} ->
               role in [:assistant, "assistant"] and String.trim(text) != ""
             end)

      control_engagement = J0AuthenticatedBaseline.engagement_id!(control_id, conversant_id)
      refute control_engagement == engagement_id

      control_pair =
        SqliteEvidence.await_committed_pair!(
          J0AuthenticatedBaseline.session_id!(control_id),
          control_engagement,
          "hello control"
        )

      refute Enum.any?(control_pair, fn {_role, text} ->
               String.contains?(text, J0AuthenticatedBaseline.preference_marker())
             end)

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end
  end

  describe "baseline measurement of index and authenticated recall denial" do
    test "does not seed Memory.index; records that the preference is absent from the index after the authenticated turn",
         ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      conversant_id = ctx.conversant.id

      assert {:ok, _reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 J0AuthenticatedBaseline.preference()
               )

      _ = J0AuthenticatedBaseline.await_provider_request!()

      # Measurement, not a product success claim. Since 2026-09-09 authenticated
      # turns index only through opt-in private conversation memory (Session
      # owner, after the acknowledged turn), which is off by default and in this
      # topology; turn.dot itself does not index. Do not seed. If this starts
      # seeing the marker, an indexing path was wired for the default config.
      index =
        J0AuthenticatedBaseline.inspect_index(
          conversationalist_id,
          J0AuthenticatedBaseline.preference_marker()
        )

      case index do
        {:ok, results} when is_list(results) ->
          refute inspect(results) =~ J0AuthenticatedBaseline.preference_marker(),
                 """
                 Unexpected: the preference was indexed on the authenticated Session path.
                 This baseline assumed session.turn_data is unproduced and finalize_query
                 is not invoked. Captured index: #{inspect(results)}
                 """

        {:error, :index_not_initialized} ->
          # Specific production-path gap: Lifecycle created the agent but the
          # semantic index never came up for recall.
          :ok

        other ->
          flunk("unexpected index inspection result: #{inspect(other)}")
      end

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end

    # Contract since 2026-09-09 (6f619c769, c8c977589): authenticated private
    # turns run with memory_write_policy :deny, so turn.dot's
    # session_memory.recall node never dispatches generic Arbor.Memory.recall.
    # Continuity runs through opt-in private conversation memory instead: the
    # Session preflight calls Memory.recall_private_conversations/3, and only
    # when :private_conversation_memory has an embedding route. That path is
    # off by default and in this topology; exercising it needs a hermetic
    # embedding route (.arbor/roadmap/0-inbox/j0-hermetic-private-memory-route.md).
    test "authenticated follow-up dispatches no generic Memory.recall (private memory off by default)",
         ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      conversant_id = ctx.conversant.id
      follow_up = J0AuthenticatedBaseline.follow_up()
      marker = J0AuthenticatedBaseline.preference_marker()

      assert OrchestratorConfig.private_conversation_memory() in [false, nil],
             """
             J0 now runs with private conversation memory enabled, so this test's
             premise (no recall on the authenticated path) no longer holds. Retarget it
             to observe Memory.recall_private_conversations/3 in the Session preflight
             (see .arbor/roadmap/0-inbox/j0-hermetic-private-memory-route.md).
             """

      _ = TraceHub.assert_supervised_turn_owner_traced!(ctx.hub)

      assert {:ok, _first} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 J0AuthenticatedBaseline.preference()
               )

      _ = J0AuthenticatedBaseline.await_provider_request!()
      refute_generic_recall!(TraceHub.drain(ctx.hub), conversationalist_id)

      _ = TraceHub.assert_supervised_turn_owner_traced!(ctx.hub)

      assert {:ok, second_reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 follow_up
               )

      assert second_reply == J0AuthenticatedBaseline.follow_up_reply()

      follow_request = J0AuthenticatedBaseline.await_provider_request!()
      newest = J0AuthenticatedBaseline.newest_user_content(follow_request)
      assert newest =~ follow_up

      events = TraceHub.drain(ctx.hub)

      dispatched =
        Enum.filter(events, fn
          {:j0_dispatched_recall, ^conversationalist_id, _query, _result} -> true
          _ -> false
        end)

      assert dispatched == [],
             """
             The authenticated follow-up dispatched generic Arbor.Memory.recall. Since
             2026-09-09 authenticated private turns must not reach it (the recall node
             only passes through Session-precomputed private recall).
             Dispatched: #{inspect(dispatched)}
             """

      # Coverage canary: the same traced Session.TaskSupervisor must observe a real
      # facade call, so the empty drain above is evidence of absence, not a missed
      # observation.
      canary_query = "j0 trace coverage canary"

      ctx.hub.task_supervisor
      |> Task.Supervisor.async_nolink(fn ->
        Arbor.Memory.recall(conversationalist_id, canary_query)
      end)
      |> Task.await(5_000)

      canary_events = TraceHub.drain(ctx.hub)

      assert Enum.any?(canary_events, fn
               {:j0_dispatched_recall, ^conversationalist_id, ^canary_query, _result} -> true
               _ -> false
             end),
             """
             TraceHub did not observe a canary Arbor.Memory.recall/2 under
             Session.TaskSupervisor #{inspect(ctx.hub.task_supervisor)}; the empty
             follow-up drain proves nothing. Events: #{inspect(canary_events)}
             """

      # Retrieved memories are prepended onto the current user turn. Prior
      # conversation history may still contain the preference the human just
      # stated; that is the transcript, not a generic Memory.recall.
      refute newest =~ marker,
             """
             The follow-up's current user turn contained the preference.
             Authenticated turns freeze memory_write_policy to :deny, so
             session_memory.recall may return only session-precomputed private
             memories. A marker here is a private-recall leak into this turn.
             Newest user content: #{inspect(newest)}
             """

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end
  end

  defp refute_generic_recall!(events, agent_id) do
    dispatched =
      Enum.filter(events, fn
        {:j0_dispatched_recall, ^agent_id, _query, _result} -> true
        _ -> false
      end)

    assert dispatched == [],
           """
           Authenticated Session turns freeze memory_write_policy to :deny.
           session_memory.recall must return precomputed private memories and
           must not call Arbor.Memory.recall/2. Observed: #{inspect(dispatched)}
           Events: #{inspect(events)}
           """
  end
end
