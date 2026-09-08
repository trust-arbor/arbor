defmodule Arbor.Commands.Journeys.J0AuthenticatedPersonalAgentBaselineTest do
  @moduledoc """
  SU-0/J0 first authenticated personal-agent journey — measurement baseline.

  Exact owner commands (this worker did not execute them):

      ./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_baseline_helpers_test.exs

      ./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_personal_agent_baseline_test.exs --include database --include sqlite --include integration

  Independently asserted boundaries: auth, reply, persistence pair, index,
  dispatched recall, untouched control, outbound denial. See the companion
  Markdown in this directory for blocked production-path assertions.

  Does not replace production turn.dot, does not seed Memory.index, does not
  catch Engine/turn failures, and does not boot this topology from test_helper.
  """

  use ExUnit.Case, async: false

  alias Arbor.Commands.J0AuthenticatedBaseline
  alias Arbor.Commands.J0AuthenticatedBaseline.{SqliteEvidence, TraceHub}
  alias Arbor.LLM.Request

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

  describe "baseline measurement of index and dispatched recall" do
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

      # Measurement, not a product success claim. Authenticated Session turns
      # run production turn.dot; session_memory.update reads session.turn_data
      # which no node produces, and AgentSeed.finalize_query is not on this
      # path. Do not seed. If this starts seeing the marker, indexing was wired.
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

    test "follow-up dispatched recall is observed independently and does not contain the preference",
         ctx do
      conversationalist_id = ctx.conversationalist.agent_id
      conversant_id = ctx.conversant.id
      follow_up = J0AuthenticatedBaseline.follow_up()

      _ = TraceHub.assert_supervised_turn_owner_traced!(ctx.hub)

      assert {:ok, _first} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 J0AuthenticatedBaseline.preference()
               )

      _ = J0AuthenticatedBaseline.await_provider_request!()
      _ = TraceHub.drain(ctx.hub)

      _ = TraceHub.assert_supervised_turn_owner_traced!(ctx.hub)

      assert {:ok, second_reply} =
               J0AuthenticatedBaseline.send_authenticated!(
                 conversant_id,
                 conversationalist_id,
                 follow_up
               )

      assert second_reply == J0AuthenticatedBaseline.follow_up_reply()

      follow_request = J0AuthenticatedBaseline.await_provider_request!()
      assert J0AuthenticatedBaseline.newest_user_content(follow_request) =~ follow_up

      events = TraceHub.drain(ctx.hub)

      dispatched =
        Enum.filter(events, fn
          {:j0_dispatched_recall, ^conversationalist_id, query, _result} ->
            query == follow_up

          _ ->
            false
        end)

      assert dispatched != [],
             """
             Empty trace drain after a follow-up turn whose owner was
             Session.TaskSupervisor #{inspect(ctx.hub.task_supervisor)}
             (do_send_message_async/5 start_child), already in traced_pids
             #{inspect(ctx.hub.traced_pids)} before send_authenticated.
             That is a missing observation of session_memory.recall /
             SessionMemory.bridge(Arbor.Memory, :recall, ...), not evidence
             that recall was absent from the product path.
             Events: #{inspect(events)}
             """

      Enum.each(dispatched, fn {:j0_dispatched_recall, _agent_id, query, result} ->
        assert query == follow_up

        assert match?({:ok, results} when is_list(results), result) or
                 result == {:error, :index_not_initialized},
               "unexpected dispatched recall result: #{inspect(result)}"

        refute inspect(result) =~ J0AuthenticatedBaseline.preference_marker(),
               """
               Dispatched recall contained the preference. This baseline expected the
               Session indexing gap (unproduced session.turn_data / finalize_query not
               on the authenticated path). Result: #{inspect(result)}
               """
      end)

      J0AuthenticatedBaseline.assert_no_escapes!(ctx.hub)
    end
  end
end
