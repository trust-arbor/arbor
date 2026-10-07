defmodule Arbor.Commands.Journeys.MindBodyChatOverheadBaselineTest do
  @moduledoc """
  Phase-gate baseline for the mind/body redesign
  (.arbor/decisions/2026-10-07-mind-body-sensorium.md, Q6): the framework
  overhead of a simple authenticated chat turn, measured before M1 and
  re-measured at every phase gate. M4 (turn becomes a cycle mode) does not
  merge without an agreed overhead budget against these numbers.

      ./bin/mix test apps/arbor_commands/test/journeys/mind_body_chat_overhead_baseline_test.exs --include benchmark

  Runs on the J0 authenticated journey topology: real `Arbor.Agent.send_message/4`,
  real Session and production turn.dot, real SQLite persistence, outbound
  closed. The model is the J0 capture adapter (instant canned reply), so model
  latency is excluded and what remains is Arbor's own cost:

    * `pre_llm_ms`  — send → provider request (the framework's share of TTFT)
    * `post_llm_ms` — provider request → reply returned (incl. persistence)
    * `total_ms`    — wall clock of `send_message/4`
    * `llm_calls`, `prompt_messages`, `prompt_bytes` per turn
    * `db_writes`, `db_queries` per turn (Ecto query telemetry)

  Caveats: J0 installs call tracing on a few MFAs (recall, adapter escapes),
  which adds a small constant; the comparison across phase gates is what
  matters, not the absolute numbers. Real-model TTFT is out of scope.
  """

  use ExUnit.Case, async: false

  alias Arbor.Commands.J0AuthenticatedBaseline
  alias Arbor.Commands.J0AuthenticatedBaseline.CaptureAdapter
  alias Arbor.LLM.Request

  @moduletag :benchmark
  @moduletag :integration
  @moduletag :database
  @moduletag :sqlite
  @moduletag timeout: 300_000

  @warmup_turns 3
  @measured_turns 20
  @repo_query_event [:arbor, :persistence, :repo, :query]
  @turn_event [:arbor, :session, :turn]

  setup_all do
    state = J0AuthenticatedBaseline.start_suite!()
    {:ok, suite: state}
  end

  setup %{suite: suite} do
    case_ctx = J0AuthenticatedBaseline.start_case!(self())
    {:ok, Map.merge(suite, case_ctx)}
  end

  test "simple chat turn overhead baseline", ctx do
    recorder = start_recorder()
    CaptureAdapter.set_parent(recorder)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@repo_query_event, @turn_event],
        &__MODULE__.handle_telemetry/4,
        recorder
      )

    try do
      human = ctx.conversant.id
      agent = ctx.conversationalist.agent_id

      for n <- 1..@warmup_turns, do: run_turn(recorder, human, agent, "warmup #{n}")

      turns =
        for n <- 1..@measured_turns do
          run_turn(recorder, human, agent, "Simple chat turn #{n}: what is 2 + 2?")
        end

      # Instrumentation must observe the turn, or the baseline is meaningless.
      for turn <- turns do
        assert turn.llm_calls >= 1, "no provider request observed: #{inspect(turn)}"
        assert turn.db_writes >= 1, "no durable write observed: #{inspect(turn)}"
      end

      report(turns)
    after
      :telemetry.detach(handler_id)
      CaptureAdapter.set_parent(self())
      send(recorder, :stop)
    end
  end

  @doc false
  def handle_telemetry(@repo_query_event, _measurements, metadata, recorder) do
    send(recorder, {:repo_query, System.monotonic_time(), write_query?(metadata)})
  end

  def handle_telemetry(@turn_event, %{duration: duration}, _metadata, recorder) do
    send(recorder, {:session_turn, System.monotonic_time(), duration})
  end

  def handle_telemetry(_event, _measurements, _metadata, _recorder), do: :ok

  defp run_turn(recorder, human, agent, content) do
    started = System.monotonic_time()
    assert {:ok, reply} = J0AuthenticatedBaseline.send_authenticated!(human, agent, content)
    assert is_binary(reply)
    finished = System.monotonic_time()

    events = recorder_events(recorder, started, finished)
    requests = for {:provider_request, t, request} <- events, do: {t, request}
    queries = for {:repo_query, _t, write?} <- events, do: write?

    {first_request_at, last_request} =
      case requests do
        [{t, _} | _] -> {t, requests |> List.last() |> elem(1)}
        [] -> {nil, nil}
      end

    %{
      total_ms: ms(finished - started),
      pre_llm_ms: if(first_request_at, do: ms(first_request_at - started)),
      post_llm_ms: if(first_request_at, do: ms(finished - first_request_at)),
      session_turn_ms:
        Enum.find_value(events, fn
          {:session_turn, _t, duration} -> ms(duration)
          _ -> nil
        end),
      llm_calls: length(requests),
      prompt_messages: prompt_messages(last_request),
      prompt_bytes: prompt_bytes(last_request),
      db_writes: Enum.count(queries, & &1),
      db_queries: length(queries)
    }
  end

  defp report(turns) do
    metrics = [
      :total_ms,
      :pre_llm_ms,
      :post_llm_ms,
      :session_turn_ms,
      :llm_calls,
      :prompt_messages,
      :prompt_bytes,
      :db_writes,
      :db_queries
    ]

    summary =
      Map.new(metrics, fn metric ->
        values = turns |> Enum.map(&Map.fetch!(&1, metric)) |> Enum.reject(&is_nil/1)
        {metric, stats(values)}
      end)

    result = %{
      harness: "j0_authenticated_journey/capture_adapter",
      measured_turns: length(turns),
      warmup_turns: @warmup_turns,
      otp: System.otp_release(),
      elixir: System.version(),
      summary: summary,
      turns: turns
    }

    IO.puts("\n=== MIND_BODY_CHAT_OVERHEAD_BASELINE ===")

    for metric <- metrics do
      s = summary[metric]

      IO.puts(
        String.pad_trailing(Atom.to_string(metric), 18) <>
          "median=#{s.median}  p95=#{s.p95}  min=#{s.min}  max=#{s.max}"
      )
    end

    IO.puts("JSON " <> Jason.encode!(result))
    IO.puts("=== END_MIND_BODY_CHAT_OVERHEAD_BASELINE ===")
  end

  defp stats([]), do: %{median: nil, p95: nil, min: nil, max: nil}

  defp stats(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      median: Enum.at(sorted, div(count - 1, 2)),
      p95: Enum.at(sorted, min(count - 1, ceil(count * 0.95) - 1)),
      min: List.first(sorted),
      max: List.last(sorted)
    }
  end

  defp ms(native),
    do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1000, 2)

  defp write_query?(%{query: query}) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.upcase()
    |> String.starts_with?(~w(INSERT UPDATE DELETE))
  end

  defp write_query?(_metadata), do: false

  defp prompt_messages(%Request{messages: messages}) when is_list(messages), do: length(messages)
  defp prompt_messages(_request), do: nil

  defp prompt_bytes(%Request{} = request),
    do: request |> J0AuthenticatedBaseline.request_transcript() |> byte_size()

  defp prompt_bytes(_request), do: nil

  # A separate process so provider requests and telemetry are timestamped when
  # they happen, not when the (blocked) test process gets to its mailbox.
  defp start_recorder do
    spawn_link(fn -> recorder_loop([]) end)
  end

  defp recorder_loop(events) do
    receive do
      {:j0_provider_request, request} ->
        recorder_loop([{:provider_request, System.monotonic_time(), request} | events])

      {:repo_query, _t, _write?} = event ->
        recorder_loop([event | events])

      {:session_turn, _t, _duration} = event ->
        recorder_loop([event | events])

      {:take, from, ref, started, finished} ->
        {window, rest} =
          Enum.split_with(events, fn event -> elem(event, 1) in started..finished//1 end)

        send(from, {ref, Enum.reverse(window)})
        recorder_loop(rest)

      :stop ->
        :ok

      _other ->
        recorder_loop(events)
    end
  end

  defp recorder_events(recorder, started, finished) do
    # Telemetry for the turn may land just after send_message/4 returns.
    Process.sleep(20)
    ref = make_ref()

    send(
      recorder,
      {:take, self(), ref, started,
       finished + System.convert_time_unit(20, :millisecond, :native)}
    )

    receive do
      {^ref, events} -> events
    after
      5_000 -> flunk("benchmark recorder did not respond")
    end
  end
end
