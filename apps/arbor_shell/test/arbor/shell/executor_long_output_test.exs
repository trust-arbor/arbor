defmodule Arbor.Shell.ExecutorLongOutputTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.Executor

  @moduletag :slow
  @moduletag timeout: 90_000

  test "a megabyte streamed over 60s with exit 0 is not cancelled" do
    script =
      "import sys,time\n" <>
        "chunk=b'x'*17477\n" <>
        "for _ in range(60):\n" <>
        "    sys.stdout.buffer.write(chunk)\n" <>
        "    sys.stdout.flush()\n" <>
        "    time.sleep(1)\n"

    {:ok, result} =
      Executor.run_direct("python3", ["-c", script], timeout: 75_000)

    assert result.exit_code == 0
    refute Map.get(result, :cancelled) == true
    refute result.killed
    assert byte_size(result.stdout) == 17_477 * 60
  end
end
