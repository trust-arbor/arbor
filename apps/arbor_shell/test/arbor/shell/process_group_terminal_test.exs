defmodule Arbor.Shell.ProcessGroupTerminalTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.ProcessGroup

  @moduletag :fast

  test "decodes legacy 5-byte terminal frames" do
    assert {:ok, :cancelled, 137, %{}} =
             ProcessGroup.decode_terminal_payload(<<3, 137::signed-big-32>>)

    assert {:ok, :normal, 0, %{}} =
             ProcessGroup.decode_terminal_payload(<<0, 0::signed-big-32>>)
  end

  test "decodes V7-16 terminal frames with sub-reason and errno" do
    payload = <<0, 0::signed-big-32, 1, 0::signed-big-32>>

    assert {:ok, :normal, 0, %{sub_reason: :hup, errno: 0}} =
             ProcessGroup.decode_terminal_payload(payload)

    cancelled = <<3, 137::signed-big-32, 4, 32::signed-big-32>>

    assert {:ok, :cancelled, 137, %{sub_reason: :write_err, errno: 32}} =
             ProcessGroup.decode_terminal_payload(cancelled)
  end

  test "decodes V7-21 descendants_reaped as a normal non-cancel frame" do
    payload = <<0, 0::signed-big-32, 11, 2::signed-big-32>>

    assert {:ok, :normal, 0, %{sub_reason: :descendants_reaped, errno: 2}} =
             ProcessGroup.decode_terminal_payload(payload)

    no_fork = <<3, 0::signed-big-32, 8, 0::signed-big-32>>

    assert {:ok, :cancelled, 0, %{sub_reason: :live_descendants, errno: 0}} =
             ProcessGroup.decode_terminal_payload(no_fork)
  end

  test "rejects truncated terminal payloads" do
    assert :error = ProcessGroup.decode_terminal_payload(<<3>>)
    assert :error = ProcessGroup.decode_terminal_payload(<<>>)
  end

  test "seed compiled build is a no-op without a pinned baseline" do
    dest =
      Path.join(
        System.tmp_dir!(),
        "compiled-build-seed-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    assert :ok = Arbor.Shell.seed_linux_compiled_dependency_build(dest)
    refute File.exists?(Path.join(dest, ".arbor-compiled-build-seeded"))
  end
end
