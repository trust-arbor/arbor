defmodule Arbor.Commands.StartTest do
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

  # The success path requires the Manager supervision tree (Registry,
  # Supervisor) to be running. Without it, the side effect returns an
  # error and we surface "/start failed: ...". These tests confirm
  # parsing routed past the parse stage and into the Manager call.
  describe "execute/2 — side-effect attempted (Manager unavailable in test env)" do
    test "template + valid args reach the side-effect stage" do
      assert {:ok, %Result{type: :error, text: text}} =
               Start.execute("fizzbuzz name=Foo runtime=arbor", ctx())

      refute String.contains?(text, "Usage:")
      refute String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "/start failed:")
    end

    test "unrelated kwargs silently skip — parse still succeeds" do
      assert {:ok, %Result{type: :error, text: text}} =
               Start.execute("fizzbuzz future_arg=42 name=Foo", ctx())

      refute String.contains?(text, "Unknown")
      assert String.contains?(text, "/start failed:")
    end
  end
end
