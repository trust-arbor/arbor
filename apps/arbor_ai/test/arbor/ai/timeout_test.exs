defmodule Arbor.AI.TimeoutTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Timeout

  @moduletag :fast

  test "security regression: every timeout alias and duplicate narrows to one ceiling" do
    assert {:ok, opts, 5} =
             Timeout.normalize(
               [timeout: 100, receive_timeout: 20, timeout_ms: 5, timeout: 80],
               1_000
             )

    assert Keyword.get_values(opts, :timeout) == [5]

    refute Enum.any?(opts, fn {key, _value} ->
             key in [:timeout_ms, :receive_timeout, :request_timeout, :stream_read_timeout_ms]
           end)
  end

  test "security regression: an invalid duplicate cannot hide behind a valid timeout" do
    assert {:error, {:invalid_timeout, {1, 4_294_967_295}}} =
             Timeout.normalize([timeout: 10, timeout: :invalid], 1_000)

    assert {:error, {:invalid_timeout, {1, 4_294_967_295}}} =
             Timeout.normalize([timeout: 10, receive_timeout: 1.5], 1_000)
  end
end
