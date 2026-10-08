defmodule Arbor.Commands.StartTest do
  # The security regression's global call-trace patterns report calls only
  # for its own traced worker, so concurrent tests are unaffected.
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Commands.Start
  alias Arbor.Contracts.Commands.{Context, Result}

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  describe "available?/1" do
    test "always true (anyone can attempt /start)" do
      assert Start.available?(ctx())
      assert Start.available?(ctx(agent_id: "agent_test"))
    end
  end

  describe "execute/2 — parse stage" do
    test "empty args returns usage error" do
      assert {:ok, %Result{text: text, type: :error}} = Start.execute("", ctx())
      assert String.contains?(text, "Usage:")
      assert String.contains?(text, "/start")
    end

    test "unknown runtime errors at parse stage" do
      assert {:ok, %Result{text: text, type: :error}} =
               Start.execute("fizzbuzz runtime=garbage", ctx())

      assert String.contains?(text, "Unknown runtime")
    end
  end

  # Decision 2026-10-08 D3: /start returns the start as an action for the
  # ingress that holds the human's proof; it performs nothing itself.
  describe "execute/2 — returns the :start_agent action" do
    test "template + valid args become the action with only the given overrides" do
      assert {:ok, %Result{type: :command_action, action: action, text: text}} =
               Start.execute("fizzbuzz name=Foo model=m-1 runtime=acp", ctx())

      assert action == {:start_agent, "fizzbuzz", [name: "Foo", model: "m-1", runtime: :acp]}
      assert text =~ "fizzbuzz"
      assert text =~ "Foo"

      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", []}}} =
               Start.execute("fizzbuzz", ctx())
    end

    test "unrelated kwargs silently skip — parse still succeeds" do
      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", [name: "Foo"]}}} =
               Start.execute("fizzbuzz future_arg=42 name=Foo", ctx())
    end

    @tag :security_regression
    test "security regression: /start performs no lifecycle effect, whatever the context claims" do
      watched = [
        {Arbor.Agent.Manager, :start_or_resume, 3},
        {Arbor.Agent.Manager, :start_agent, 2},
        {Arbor.Agent.Manager, :resume_agent, 2},
        {Arbor.Agent.Lifecycle, :create, 2},
        {Arbor.Agent.Lifecycle, :start, 2}
      ]

      context =
        ctx(
          origin: :dashboard,
          user_id: "human_claimed",
          user_principal: %{id: "human_claimed", session_token: "claimed"}
        )

      {result, calls} = observe(watched, fn -> Start.execute("fizzbuzz name=Foo", context) end)

      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", [name: "Foo"]}}} = result
      assert calls == []
    end
  end

  # A process cannot trace its own calls, so the command runs in a worker.
  defp observe(watched, fun) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run -> send(parent, {:start_result, self(), fun.()})
        end
      end)

    try do
      # A pattern only applies to a loaded module; a lazily loaded one would go
      # untraced and the refutation would pass vacuously.
      for {module, _function, _arity} = mfa <- watched do
        Code.ensure_loaded!(module)
        1 = :erlang.trace_pattern(mfa, true, [:global])
      end

      1 = :erlang.trace(worker, true, [:call])
      send(worker, :run)

      result =
        receive do
          {:start_result, ^worker, result} ->
            result

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            flunk("worker failed: #{inspect(reason)}")
        after
          15_000 -> flunk("/start did not return")
        end

      barrier = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^barrier}, 5_000
      {result, drain(worker, [])}
    after
      for mfa <- watched, do: :erlang.trace_pattern(mfa, false, [:global])
    end
  end

  defp drain(worker, calls) do
    receive do
      {:trace, ^worker, :call, {module, function, _args}} ->
        drain(worker, [{module, function} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
