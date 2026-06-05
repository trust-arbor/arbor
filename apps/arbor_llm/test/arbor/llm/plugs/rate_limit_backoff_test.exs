defmodule Arbor.LLM.Plugs.RateLimitBackoffTest do
  @moduledoc """
  Tests for the rate-limit backoff plug. Two pieces of dependency
  injection make this testable without req_llm:

    - `:rate_limit_backoff_sleep_fn` Application env replaces
      `Process.sleep/1` so the suite doesn't actually sleep.
    - `:rate_limit_backoff_dispatch_fn` Application env replaces
      `Plugs.Dispatch.call/1` with a test stub that returns canned
      responses for each redispatch.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.RateLimitBackoff
  alias Arbor.LLM.ProviderError

  setup do
    {:ok, sleep_log} = Agent.start_link(fn -> [] end)
    {:ok, dispatch_log} = Agent.start_link(fn -> {[], []} end)

    Application.put_env(
      :arbor_llm,
      :rate_limit_backoff_sleep_fn,
      fn ms -> Agent.update(sleep_log, &[ms | &1]) end
    )

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :rate_limit_backoff_sleep_fn)
      Application.delete_env(:arbor_llm, :rate_limit_backoff_dispatch_fn)
      Application.delete_env(:arbor_llm, RateLimitBackoff)
    end)

    %{sleep_log: sleep_log, dispatch_log: dispatch_log}
  end

  defp sleeps(agent), do: Agent.get(agent, & &1) |> Enum.reverse()
  defp redispatch_count(agent), do: Agent.get(agent, fn {_, calls} -> length(calls) end)

  # Install a sequence of responses for redispatch. The Nth retry pops
  # the Nth response. The plug calls Plugs.Dispatch's substitute with a
  # fresh Call (result cleared); the stub stamps the next response.
  defp install_dispatch_seq(dispatch_log, responses) do
    Agent.update(dispatch_log, fn _ -> {responses, []} end)

    Application.put_env(
      :arbor_llm,
      :rate_limit_backoff_dispatch_fn,
      fn %Call{} = call ->
        Agent.get_and_update(dispatch_log, fn {[head | rest], calls} ->
          {%{call | result: head}, {rest, [call | calls]}}
        end)
      end
    )
  end

  defp build_call(opts) do
    %Call{
      operation: Keyword.get(opts, :operation, :complete),
      request: {"openai:gpt-4o", [%{role: :user, content: "hi"}], []},
      result: Keyword.get(opts, :result),
      halted: Keyword.get(opts, :halted, false),
      assigns: Keyword.get(opts, :assigns, %{}),
      metadata: %{}
    }
  end

  defp rate_limit_error(opts \\ []) do
    %ProviderError{
      message: "rate limited",
      provider: Keyword.get(opts, :provider, "openai"),
      status: Keyword.get(opts, :status, 429),
      retryable: true,
      retry_after_ms: Keyword.get(opts, :retry_after_ms)
    }
  end

  describe "passthrough cases" do
    test "halted: true → returns call unchanged" do
      call = build_call(halted: true, result: {:error, rate_limit_error()})
      assert RateLimitBackoff.call(call) == call
    end

    test ":stream operation → skips retry (streams are stateful)" do
      call = build_call(operation: :stream, result: {:error, rate_limit_error()})
      assert RateLimitBackoff.call(call) == call
    end

    test "success result → no-op" do
      call = build_call(result: {:ok, "all good"})
      assert RateLimitBackoff.call(call) == call
    end

    test "non-rate-limit error → no-op" do
      call = build_call(result: {:error, :something_else})
      assert RateLimitBackoff.call(call) == call
    end

    test "ProviderError with 400 status → no-op" do
      err = %ProviderError{
        message: "bad request",
        provider: "openai",
        status: 400,
        retryable: false
      }

      call = build_call(result: {:error, err})
      assert RateLimitBackoff.call(call) == call
    end
  end

  describe "rate-limit detection" do
    test "HTTP 429 ProviderError triggers retry", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 1)
      install_dispatch_seq(dispatch_log, [{:ok, "after backoff"}])

      result = RateLimitBackoff.call(build_call(result: {:error, rate_limit_error()}))

      assert result.result == {:ok, "after backoff"}
      assert length(sleeps(sleep_log)) == 1
      assert redispatch_count(dispatch_log) == 1
    end

    test ":rate_limited atom triggers retry", %{sleep_log: sleep_log, dispatch_log: dispatch_log} do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 1)
      install_dispatch_seq(dispatch_log, [{:ok, "back"}])

      result = RateLimitBackoff.call(build_call(result: {:error, :rate_limited}))
      assert result.result == {:ok, "back"}
      assert length(sleeps(sleep_log)) == 1
    end

    test "{:http_status, 429} triggers retry", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 1)
      install_dispatch_seq(dispatch_log, [{:ok, "back"}])

      result = RateLimitBackoff.call(build_call(result: {:error, {:http_status, 429}}))
      assert result.result == {:ok, "back"}
      assert length(sleeps(sleep_log)) == 1
    end
  end

  describe "delay computation" do
    test "uses retry_after_ms from provider when present", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 1)
      install_dispatch_seq(dispatch_log, [{:ok, "back"}])

      err = rate_limit_error(retry_after_ms: 3_500)
      RateLimitBackoff.call(build_call(result: {:error, err}))

      assert sleeps(sleep_log) == [3_500]
    end

    test "exponential backoff when retry_after_ms missing", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff,
        max_retries: 2,
        initial_backoff_ms: 100,
        backoff_factor: 2.0
      )

      install_dispatch_seq(dispatch_log, [
        {:error, rate_limit_error()},
        {:ok, "finally"}
      ])

      result = RateLimitBackoff.call(build_call(result: {:error, rate_limit_error()}))

      assert result.result == {:ok, "finally"}
      # First retry: initial * 2^0 = 100; second retry: initial * 2^1 = 200
      assert sleeps(sleep_log) == [100, 200]
    end

    test "delay capped at :max_delay_ms", %{sleep_log: sleep_log, dispatch_log: dispatch_log} do
      Application.put_env(:arbor_llm, RateLimitBackoff,
        max_retries: 1,
        max_delay_ms: 5_000
      )

      install_dispatch_seq(dispatch_log, [{:ok, "back"}])

      err = rate_limit_error(retry_after_ms: 999_999)
      RateLimitBackoff.call(build_call(result: {:error, err}))

      assert sleeps(sleep_log) == [5_000]
    end
  end

  describe "retry exhaustion" do
    test "max_retries reached → returns last error", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 2)
      err = rate_limit_error(retry_after_ms: 100)

      install_dispatch_seq(dispatch_log, [{:error, err}, {:error, err}])

      result = RateLimitBackoff.call(build_call(result: {:error, err}))

      assert {:error, %ProviderError{status: 429}} = result.result
      assert length(sleeps(sleep_log)) == 2
      assert redispatch_count(dispatch_log) == 2
    end

    test "non-rate-limit error mid-loop stops the retry chain", %{
      sleep_log: sleep_log,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 3)
      err_429 = rate_limit_error(retry_after_ms: 100)

      err_500 = %ProviderError{
        message: "server",
        provider: "openai",
        status: 500,
        retryable: true
      }

      install_dispatch_seq(dispatch_log, [{:error, err_500}, {:error, err_429}])

      result = RateLimitBackoff.call(build_call(result: {:error, err_429}))

      # Stops on 500 (not a rate-limit), even though more retries remain
      assert {:error, %ProviderError{status: 500}} = result.result
      assert length(sleeps(sleep_log)) == 1
      assert redispatch_count(dispatch_log) == 1
    end
  end

  describe "telemetry" do
    test "emits per retry with attempt + delay + provider", %{
      sleep_log: _,
      dispatch_log: dispatch_log
    } do
      Application.put_env(:arbor_llm, RateLimitBackoff, max_retries: 1)
      install_dispatch_seq(dispatch_log, [{:ok, "ok"}])

      handler_id = "rate-limit-backoff-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :llm, :rate_limit_backoff],
        fn evt, meas, meta, _ ->
          send(test_pid, {:telemetry, evt, meas, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      err = rate_limit_error(retry_after_ms: 250)
      RateLimitBackoff.call(build_call(result: {:error, err}))

      assert_receive {:telemetry, [:arbor, :llm, :rate_limit_backoff], %{count: 1}, metadata}, 500

      assert metadata.attempt == 1
      assert metadata.delay_ms == 250
      assert metadata.retry_after_ms_from_provider == 250
      assert metadata.operation == :complete
      assert metadata.provider == "openai"
    end
  end
end
