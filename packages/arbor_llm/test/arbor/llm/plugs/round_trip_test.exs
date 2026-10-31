defmodule Arbor.LLM.Plugs.RoundTripTest do
  @moduledoc """
  End-to-end round-trip: install a fake Dispatch plug that returns a
  known response, run the call through `[Dispatch, Record]`, then run
  a fresh call (same request) through `[Replay, Dispatch, Record]`
  and verify:

    1. The replayed result has the same shape as the original.
    2. The replayed call is halted with `replayed_from` metadata.
    3. Record does NOT re-record the replay (timestamp unchanged).
    4. A fresh call with a different request DOES fall through to
       the live Dispatch and records a new fixture.

  This is the load-bearing claim of the whole record/replay system —
  if these break, nothing else matters.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.Pipeline
  alias Arbor.LLM.Plugs.Fixture
  alias Arbor.LLM.Plugs.Record
  alias Arbor.LLM.Plugs.Replay
  alias Arbor.LLM.Plugs.StalenessWarn

  # A fake terminal plug that returns the response stashed in the
  # process dictionary. Lets us run a "record" pass with a known
  # output and assert downstream replay behavior.
  defmodule FakeDispatch do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call
    def call(%Call{result: nil} = call), do: %{call | result: Process.get(:fake_result)}
    def call(%Call{} = call), do: call
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_llm_round_trip_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:arbor_llm, :recorder)
    Application.put_env(:arbor_llm, :recorder, fixtures_path: tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Process.delete(:fake_result)

      case original do
        nil -> Application.delete_env(:arbor_llm, :recorder)
        v -> Application.put_env(:arbor_llm, :recorder, v)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "record → replay round-trip via Pipeline.through/2" do
    test "replay reconstructs the same response shape" do
      response =
        req_response("Pong",
          finish_reason: :tool_calls,
          tool_calls: [ReqLLM.ToolCall.new("call_1", "ping", ~s({"target":"localhost"}))],
          usage: %{input_tokens: 10, output_tokens: 2, total_cost: 1.0e-6}
        )

      Process.put(:fake_result, {:ok, response})

      request = {"openai:fake-model", [%{role: :user, content: "ping"}], [temperature: 0.0]}

      # Pass 1: record.
      record_pass =
        :complete
        |> Call.new(request)
        |> Pipeline.through([Replay, FakeDispatch, Record])

      assert {:ok, ^response} = record_pass.result
      assert record_pass.metadata[:recorded_to] == Fixture.path_for(record_pass)
      refute record_pass.halted

      # Pass 2: replay (same request).
      Process.put(:fake_result, {:error, :should_not_be_called})

      replay_pass =
        :complete
        |> Call.new(request)
        |> Pipeline.through([Replay, FakeDispatch, Record])

      # Halt fires (mutating plugs skip), FakeDispatch's halted clause
      # passes through, Record's halted clause passes through.
      assert replay_pass.halted == true
      assert {:ok, replayed} = replay_pass.result

      # The reconstructed response matches the original on the
      # round-trippable fields:
      assert ReqLLM.Response.text(replayed) == ReqLLM.Response.text(response)
      assert replayed.finish_reason == response.finish_reason
      assert replayed.usage[:input_tokens] == 10
      assert replayed.usage[:total_cost] == 1.0e-6

      # Content-parts kind survived the atom round-trip.
      kinds = Enum.map(replayed.message.content, & &1.type)
      assert :text in kinds
      assert [%ReqLLM.ToolCall{id: "call_1"}] = replayed.message.tool_calls

      # Provenance metadata is set.
      assert replay_pass.metadata.replayed_from == Fixture.path_for(replay_pass)
      assert %DateTime{} = replay_pass.metadata.recorded_at

      # Record did NOT re-record the replay.
      refute Map.has_key?(replay_pass.metadata, :recorded_to)
    end

    test "fresh request falls through to Dispatch and records a new fixture", %{tmp_dir: tmp_dir} do
      response_a = req_response("A")
      response_b = req_response("B")

      # Record fixture A.
      Process.put(:fake_result, {:ok, response_a})

      :complete
      |> Call.new({"openai:fake", [%{role: :user, content: "a"}], []})
      |> Pipeline.through([Replay, FakeDispatch, Record])

      # Different request → different hash → different fixture path.
      Process.put(:fake_result, {:ok, response_b})

      pass =
        :complete
        |> Call.new({"openai:fake", [%{role: :user, content: "DIFFERENT"}], []})
        |> Pipeline.through([Replay, FakeDispatch, Record])

      # Fell through to Dispatch (got B, not the replay of A).
      refute pass.halted
      assert {:ok, %ReqLLM.Response{} = response} = pass.result
      assert ReqLLM.Response.text(response) == "B"
      refute Map.has_key?(pass.metadata, :replayed_from)
      assert pass.metadata[:recorded_to] == Fixture.path_for(pass)

      # Two distinct fixtures on disk.
      assert length(File.ls!(tmp_dir)) == 2
    end

    test "StalenessWarn fires on the replayed (halted) call" do
      import ExUnit.CaptureLog

      Application.put_env(:arbor_llm, :fixture_max_age_days, 0)

      response = req_response("stale")
      Process.put(:fake_result, {:ok, response})

      request = {"openai:fake", [], []}

      # Record.
      :complete
      |> Call.new(request)
      |> Pipeline.through([Replay, FakeDispatch, Record])

      # Backdate the file's recorded_at so StalenessWarn has something
      # to flag (the just-recorded fixture is 0 days old).
      path = :complete |> Call.new(request) |> Fixture.path_for()
      contents = File.read!(path)
      stale_ts = DateTime.add(DateTime.utc_now(), -10, :day) |> DateTime.to_iso8601()

      backdated =
        String.replace(contents, ~r/"recorded_at":\s*"[^"]+"/, ~s("recorded_at": "#{stale_ts}"))

      File.write!(path, backdated)
      # Sanity check: the substitution actually landed.
      assert File.read!(path) =~ stale_ts

      # Replay through full pipeline including StalenessWarn — the
      # warning should fire because the fixture is now "10 days old"
      # with max_age=0.
      log =
        capture_log(fn ->
          replay =
            :complete
            |> Call.new(request)
            |> Pipeline.through([Replay, FakeDispatch, Record, StalenessWarn])

          assert replay.halted == true
        end)

      assert log =~ "LLM fixture is"
      assert log =~ "days old"

      Application.delete_env(:arbor_llm, :fixture_max_age_days)
    end
  end

  defp req_response(text, opts \\ []) do
    %ReqLLM.Response{
      id: "response-test",
      model: "fake-model",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text)],
        tool_calls: Keyword.get(opts, :tool_calls)
      },
      stream?: false,
      stream: nil,
      usage: Keyword.get(opts, :usage, %{}),
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      provider_meta: %{},
      error: nil
    }
  end
end
