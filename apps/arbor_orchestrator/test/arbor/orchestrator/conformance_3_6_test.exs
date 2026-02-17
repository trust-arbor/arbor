defmodule Arbor.Orchestrator.Conformance36Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine

  test "3.6 standard preset applies max attempts when max_retries is omitted" do
    dot = """
    digraph Flow {
      retry_policy="standard"
      start [shape=Mdiamond]
      flaky [simulate="retry", retry_jitter=false]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :success

    retry_events =
      collect_retry_events([], 10)

    assert length(retry_events) == 4
    assert Enum.map(retry_events, & &1.attempt) == [1, 2, 3, 4]
  end

  test "3.6 linear preset keeps fixed backoff delay when jitter is disabled" do
    dot = """
    digraph Flow {
      retry_policy="linear"
      start [shape=Mdiamond]
      flaky [simulate="retry", retry_jitter=false]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :success
    retry_events = collect_retry_events([], 10)
    assert Enum.map(retry_events, & &1.delay_ms) == [500, 500]
  end

  test "3.6 delay is capped by retry_max_delay_ms" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=3, retry_initial_delay_ms=200, retry_backoff_factor=2.0, retry_max_delay_ms=250, retry_jitter=false]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :success
    retry_events = collect_retry_events([], 10)
    assert Enum.map(retry_events, & &1.delay_ms) == [200, 250, 250]
  end

  test "3.6 jitter is applied when enabled" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=1, retry_initial_delay_ms=10, retry_backoff_factor=1.0, retry_max_delay_ms=10, retry_jitter=true]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               on_event: on_event,
               sleep_fn: fn _ -> :ok end,
               rand_fn: fn -> 0.0 end
             )

    assert result.final_outcome.status == :success
    assert_receive {:event, %{type: :stage_retrying, delay_ms: 5}}
  end

  test "3.6 should_retry predicate classifies transient vs terminal errors" do
    assert Engine.should_retry_exception?(
             RuntimeError.exception("network timeout")
           )

    assert Engine.should_retry_exception?(
             RuntimeError.exception("HTTP 429 rate limit")
           )

    assert Engine.should_retry_exception?(
             RuntimeError.exception("provider 5xx")
           )

    refute Engine.should_retry_exception?(
             RuntimeError.exception("401 unauthorized")
           )

    refute Engine.should_retry_exception?(
             RuntimeError.exception("403 forbidden")
           )

    refute Engine.should_retry_exception?(
             RuntimeError.exception("400 bad request")
           )

    refute Engine.should_retry_exception?(
             RuntimeError.exception("validation failed")
           )
  end

  defp collect_retry_events(events, 0), do: Enum.reverse(events)

  defp collect_retry_events(events, remaining) do
    receive do
      {:event, %{type: :stage_retrying} = event} ->
        collect_retry_events([event | events], remaining - 1)

      {:event, _other} ->
        collect_retry_events(events, remaining)
    after
      5 ->
        Enum.reverse(events)
    end
  end
end
