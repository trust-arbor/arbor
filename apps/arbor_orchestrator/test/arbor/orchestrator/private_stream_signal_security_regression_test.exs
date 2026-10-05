Code.require_file("../../support/private_stream_branch_fixture.exs", __DIR__)
Code.require_file("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)

defmodule Arbor.Orchestrator.PrivateStreamSignalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.StreamEvent
  alias Arbor.Orchestrator.TestSupport.PrivateStreamBranchFixture, as: Fixture

  @moduletag integration: true, database: true, isolated_repo: true, security_regression: true
  @first "Private café prefix 🌲 "
  @second "東京 final answer"

  defmodule OfflineStreamProvider do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "lm_studio"
    def complete(_request, _opts), do: {:error, :offline_fixture_requires_actual_stream}

    def stream(request, _opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :private_stream_signal_recipient)
      send(observer, {:actual_provider_request, request.provider, request.model, request.runtime})

      Stream.resource(
        fn -> {0, make_ref()} end,
        fn
          {0, ref} ->
            {[%StreamEvent{type: :delta, data: %{text: "Private café prefix 🌲 "}}], {1, ref}}

          {1, ref} ->
            send(observer, {:actual_provider_barrier, self(), ref, :first})

            receive do
              {:release_actual_provider, ^ref, :first} ->
                {[%StreamEvent{type: :delta, data: %{text: "東京 final answer"}}], {2, ref}}
            after
              15_000 -> raise "Controlled offline provider first-prefix barrier expired"
            end

          {2, ref} ->
            send(observer, {:actual_provider_barrier, self(), ref, :finish})

            receive do
              {:release_actual_provider, ^ref, :finish} ->
                {[%StreamEvent{type: :finish, data: %{reason: :stop, usage: %{}}}], {3, ref}}
            after
              15_000 -> raise "Controlled offline provider final-prefix barrier expired"
            end

          {3, ref} ->
            {:halt, {3, ref}}
        end,
        fn {_step, ref} -> send(observer, {:actual_provider_enumeration_closed, self(), ref}) end
      )
    end
  end

  test "security regression: real private Branch streaming and completion expose only metadata to unprivileged agent-signal observers" do
    Process.flag(:sensitive, true)
    fixture = Fixture.open!(OfflineStreamProvider)
    observer = self()
    tag = make_ref()
    target = fixture.target

    try do
      assert {:error, :unauthorized} =
               Arbor.Signals.subscribe("security.*", fn _ -> :ok end, async: false)

      assert {:ok, subscription} =
               Arbor.Signals.subscribe(
                 "agent.*",
                 fn signal ->
                   if signal.data[:agent_id] == target and
                        signal.type in [
                          :stream_delta,
                          :stream_finish,
                          :llm_call_started,
                          :llm_call_completed
                        ],
                      do: send(observer, {tag, signal})

                   :ok
                 end,
                 async: false
               )

      try do
        user_text = "Private ordinary Unicode request 👩🏽‍💻"
        command_id = Fixture.submit!(fixture, user_text)

        assert_receive {:actual_provider_request, provider, "private-stream-signal-fixture",
                        :arbor},
                       5_000

        assert provider in ["lmstudio", "lm_studio", :lmstudio]
        assert_receive {:actual_provider_barrier, worker, ref, :first}, 5_000
        first_activity = Fixture.preview!(fixture, command_id, @first)
        assert first_activity.command_id == command_id
        assert_receive {^tag, %{type: :stream_delta, data: first_delta}}, 5_000
        assert {:ok, %{head: 0, entries: []}} = Fixture.window!(fixture)
        assert Fixture.sql_pair!(fixture) == []

        # The same private preview remains behind a fresh exact engagement fence.
        assert {:error, :conversation_scope_changed} =
                 Arbor.Agent.conversation_activity(fixture.subject, fixture.target,
                   session_token: fixture.token,
                   expected_engagement_id: "eng_" <> String.duplicate("f", 32)
                 )

        send(worker, {:release_actual_provider, ref, :first})
        assert_receive {:actual_provider_barrier, ^worker, ^ref, :finish}, 5_000
        second_activity = Fixture.preview!(fixture, command_id, @first <> @second)
        assert second_activity.command_id == command_id
        assert_receive {^tag, %{type: :stream_delta, data: second_delta}}, 5_000
        assert Fixture.sql_pair!(fixture) == []
        send(worker, {:release_actual_provider, ref, :finish})
        completed = Fixture.completed!(fixture, command_id)
        assert completed.outcome.text == @first <> @second
        assert_receive {:actual_provider_enumeration_closed, ^worker, ^ref}, 5_000
        assert_receive {^tag, %{type: :llm_call_completed, data: completion}}, 5_000
        assert_receive {^tag, %{type: :stream_finish, data: %{source: :turn}}}, 5_000

        # Check both actual producer facts together after normal completion.
        # The predecessor discloses both delta bodies and the completed preview.
        assert {Map.has_key?(first_delta, :text), Map.has_key?(second_delta, :text),
                Map.has_key?(completion, :response_preview)} ==
                 {false, false, false}

        assert first_delta.delta_length == byte_size(@first)
        assert second_delta.delta_length == byte_size(@second)
        assert completion.response_length == String.length(@first <> @second)
        assert completion.use_tools == false

        for payload <- [first_delta, second_delta, completion] do
          rendered = inspect(payload, limit: :infinity, printable_limit: :infinity)
          refute rendered =~ @first
          refute rendered =~ @second
          refute rendered =~ fixture.token
          refute rendered =~ user_text
        end

        assert {:ok, window} = Fixture.window!(fixture)
        assert window.head == 2

        assert Enum.map(window.entries, &{&1.role, &1.content}) == [
                 {"user", user_text},
                 {"assistant", @first <> @second}
               ]

        assert [["user", user_json], ["assistant", assistant_json]] = Fixture.sql_pair!(fixture)
        assert json_text(user_json) == user_text
        assert json_text(assistant_json) == @first <> @second
      after
        assert :ok = Arbor.Signals.unsubscribe(subscription)
      end
    after
      assert :ok = Fixture.close!(fixture)
    end
  end

  defp json_text(raw) do
    parts = Jason.decode!(raw)
    assert is_list(parts)

    Enum.map_join(parts, fn part ->
      # Raw SQLite SQL bypasses Ecto's nested {:array, :map} loaders.
      decoded = if is_binary(part), do: Jason.decode!(part), else: part
      %{"type" => "text", "text" => text} = decoded
      assert is_binary(text)
      text
    end)
  end
end
