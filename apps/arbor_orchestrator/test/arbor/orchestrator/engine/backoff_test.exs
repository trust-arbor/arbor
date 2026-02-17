defmodule Arbor.Orchestrator.Engine.BackoffTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Backoff

  describe "preset/1" do
    test "standard has 5 attempts with exponential backoff" do
      b = Backoff.preset(:standard)
      assert b.max_attempts == 5
      assert b.initial_delay_ms == 200
      assert b.backoff_factor == 2.0
      assert b.jitter == true
    end

    test "linear has factor 1.0 (constant delay)" do
      b = Backoff.preset(:linear)
      assert b.backoff_factor == 1.0
      assert b.max_attempts == 3
    end

    test "patient has higher initial delay and factor" do
      b = Backoff.preset(:patient)
      assert b.initial_delay_ms == 2_000
      assert b.backoff_factor == 3.0
    end

    test "none has single attempt" do
      b = Backoff.preset(:none)
      assert b.max_attempts == 1
      assert b.jitter == false
    end

    test "unknown name falls back to none" do
      assert Backoff.preset(:bogus) == Backoff.preset(:none)
    end
  end

  describe "from_string/1" do
    test "resolves string names case-insensitively" do
      assert Backoff.from_string("Standard") == Backoff.preset(:standard)
      assert Backoff.from_string("PATIENT") == Backoff.preset(:patient)
    end

    test "unknown string falls back to none" do
      assert Backoff.from_string("nonexistent") == Backoff.preset(:none)
    end
  end

  describe "delay_ms/2" do
    test "exponential growth with factor 2.0" do
      b = Backoff.preset(:standard)
      assert Backoff.delay_ms(b, 1) == 200
      assert Backoff.delay_ms(b, 2) == 400
      assert Backoff.delay_ms(b, 3) == 800
    end

    test "linear stays constant with factor 1.0" do
      b = Backoff.preset(:linear)
      assert Backoff.delay_ms(b, 1) == 500
      assert Backoff.delay_ms(b, 2) == 500
      assert Backoff.delay_ms(b, 3) == 500
    end

    test "respects max_delay_ms cap" do
      b = %Backoff{initial_delay_ms: 10_000, backoff_factor: 10.0, max_delay_ms: 50_000}
      assert Backoff.delay_ms(b, 3) == 50_000
    end
  end

  describe "preset_names/0" do
    test "returns all preset names" do
      names = Backoff.preset_names()
      assert :standard in names
      assert :linear in names
      assert :none in names
    end
  end
end
