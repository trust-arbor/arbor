defmodule Arbor.LLM.FallbackLoopTest do
  @moduledoc """
  Tests for the generic fallback-chain executor. Both
  `Arbor.AI.Runtime.Dispatch` and the LlmHandler tool-loop wrapper
  delegate their fallback control flow to this module, so the loop
  semantics need to be airtight before either consumer trusts it.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.FallbackLoop

  # Single-field "attempt" — typically a Request struct in production.
  # Tests use a plain map so the override application is easy to read.
  defp simple_override_fn do
    fn attempt, override ->
      if Map.has_key?(override, :model) or Map.has_key?(override, :provider) do
        {:ok, Map.merge(attempt, override)}
      else
        :no_change
      end
    end
  end

  describe "run/3 — empty chain" do
    test "primary success returns immediately" do
      do_call = fn _ -> {:ok, :primary_result} end

      assert {:ok, :primary_result} =
               FallbackLoop.run(%{}, [],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end

    test "primary failure (eligible) → returns error since chain is empty" do
      do_call = fn _ -> {:error, :timeout} end

      assert {:error, :timeout} =
               FallbackLoop.run(%{}, [],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end

    test "primary failure (non-eligible) → returns error" do
      do_call = fn _ -> {:error, :bad_prompt} end

      assert {:error, :bad_prompt} =
               FallbackLoop.run(%{}, [],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end
  end

  describe "run/3 — primary failure semantics" do
    test "non-eligible primary error propagates immediately, chain untouched" do
      counter = :counters.new(1, [])

      do_call = fn _ ->
        :counters.add(counter, 1, 1)
        {:error, :bad_prompt}
      end

      assert {:error, :bad_prompt} =
               FallbackLoop.run(%{}, [%{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )

      assert :counters.get(counter, 1) == 1
    end

    test "eligible primary error → first fallback runs" do
      attempts = :counters.new(1, [])

      do_call = fn attempt ->
        :counters.add(attempts, 1, 1)

        if attempt[:model] == "fallback-1" do
          {:ok, {:served_by, "fallback-1"}}
        else
          {:error, :timeout}
        end
      end

      assert {:ok, {:served_by, "fallback-1"}} =
               FallbackLoop.run(%{model: "primary"}, [%{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )

      assert :counters.get(attempts, 1) == 2
    end
  end

  describe "run/3 — chain walking" do
    test "walks to second fallback when first fails with eligible error" do
      do_call = fn attempt ->
        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:error, :rate_limited}
          "fallback-2" -> {:ok, :served_by_fallback_2}
        end
      end

      assert {:ok, :served_by_fallback_2} =
               FallbackLoop.run(
                 %{model: "primary"},
                 [%{model: "fallback-1"}, %{model: "fallback-2"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end

    test "stops at first eligible→non-eligible boundary in the chain" do
      attempts = :counters.new(1, [])

      do_call = fn attempt ->
        :counters.add(attempts, 1, 1)

        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:error, :bad_prompt}
          "fallback-2" -> {:ok, :should_not_be_reached}
        end
      end

      assert {:error, :bad_prompt} =
               FallbackLoop.run(
                 %{model: "primary"},
                 [%{model: "fallback-1"}, %{model: "fallback-2"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )

      assert :counters.get(attempts, 1) == 2
    end

    test "all attempts fail → returns last error" do
      do_call = fn attempt ->
        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:error, :rate_limited}
          "fallback-2" -> {:error, :network_error}
        end
      end

      assert {:error, :network_error} =
               FallbackLoop.run(
                 %{model: "primary"},
                 [%{model: "fallback-1"}, %{model: "fallback-2"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end
  end

  describe "run/3 — :no_change semantics" do
    test "entry where apply_override returns :no_change is skipped without calling do_call" do
      attempts = :counters.new(1, [])

      do_call = fn attempt ->
        :counters.add(attempts, 1, 1)

        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:ok, :served_by_fallback_1}
        end
      end

      # First chain entry has no relevant fields → :no_change, skipped.
      # Second entry has :model → applied.
      assert {:ok, :served_by_fallback_1} =
               FallbackLoop.run(
                 %{model: "primary"},
                 [%{runtime: :ignored}, %{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )

      # Primary + fallback-1 = 2. The :no_change entry didn't fire do_call.
      assert :counters.get(attempts, 1) == 2
    end

    test "all chain entries skip → returns the original primary error" do
      do_call = fn _ -> {:error, :timeout} end

      assert {:error, :timeout} =
               FallbackLoop.run(%{}, [%{runtime: :a}, %{runtime: :b}, %{runtime: :c}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end
  end

  describe "run/3 — on_fallback hook" do
    test "on_fallback is called once per fallback attempt, not on primary" do
      pid = self()

      do_call = fn attempt ->
        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:ok, :ok}
        end
      end

      on_fallback = fn initial, override, last_error ->
        send(pid, {:fallback_called, initial, override, last_error})
      end

      assert {:ok, _} =
               FallbackLoop.run(%{model: "primary"}, [%{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn(),
                 on_fallback: on_fallback
               )

      assert_receive {:fallback_called, %{model: "primary"}, %{model: "fallback-1"},
                      {:error, :timeout}}
    end

    test "on_fallback is NOT called when an entry is :no_change" do
      pid = self()
      do_call = fn _ -> {:error, :timeout} end

      on_fallback = fn _, override, _ -> send(pid, {:fallback_called, override}) end

      # Entry is :no_change → on_fallback should not fire for this entry.
      FallbackLoop.run(%{}, [%{runtime: :ignored}],
        do_call: do_call,
        apply_override: simple_override_fn(),
        on_fallback: on_fallback
      )

      refute_receive {:fallback_called, _}, 50
    end
  end

  describe "run/3 — custom eligibility predicate" do
    test "custom :eligible? overrides Retry.fallback_eligible?" do
      # Mark :custom_transient_error as eligible even though Retry
      # wouldn't classify it as such.
      do_call = fn attempt ->
        case attempt[:model] do
          "primary" -> {:error, :custom_transient_error}
          "fallback-1" -> {:ok, :ok}
        end
      end

      eligible_predicate = fn
        :custom_transient_error -> true
        _ -> false
      end

      assert {:ok, :ok} =
               FallbackLoop.run(%{model: "primary"}, [%{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn(),
                 eligible?: eligible_predicate
               )
    end

    test "default eligibility uses Retry.fallback_eligible? — confirms :timeout eligible" do
      do_call = fn attempt ->
        case attempt[:model] do
          "primary" -> {:error, :timeout}
          "fallback-1" -> {:ok, :ok}
        end
      end

      # No :eligible? opt → defaults to Retry.fallback_eligible?
      assert {:ok, :ok} =
               FallbackLoop.run(%{model: "primary"}, [%{model: "fallback-1"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end
  end

  describe "run/3 — overrides apply to original, not previous attempt" do
    test "each entry's override is applied to the initial attempt independently" do
      attempts = :counters.new(1, [])

      do_call = fn attempt ->
        :counters.add(attempts, 1, 1)

        # If overrides chained on top of each other, we'd see
        # provider AND model swapped on the second fallback. Asserting
        # that the second fallback sees provider="anthropic" (original),
        # NOT provider="openai" (from fallback-1).
        case {attempt[:model], attempt[:provider]} do
          {"primary", _} -> {:error, :timeout}
          {"fb-1", "openai"} -> {:error, :timeout}
          {"fb-2", "anthropic"} -> {:ok, :independent_overrides_confirmed}
          other -> {:error, {:unexpected_attempt, other, attempt}}
        end
      end

      assert {:ok, :independent_overrides_confirmed} =
               FallbackLoop.run(
                 %{model: "primary", provider: "anthropic"},
                 [%{model: "fb-1", provider: "openai"}, %{model: "fb-2"}],
                 do_call: do_call,
                 apply_override: simple_override_fn()
               )
    end
  end
end
