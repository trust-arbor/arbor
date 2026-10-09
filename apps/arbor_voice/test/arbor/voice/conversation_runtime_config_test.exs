defmodule Arbor.Voice.ConversationRuntimeConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :conversation_runtime_config

  test "test runtime preserves timezone conversion without starting the network updater" do
    # Read the effective startup configuration; never repair it inside the test.
    assert Application.get_env(:time_zone_info, :update) == :disabled
    assert Application.get_env(:tzdata, :autoupdate) == :disabled
    assert {:ok, _started} = Application.ensure_all_started(:time_zone_info)

    assert TimeZoneInfo.state() == :ok
    assert TimeZoneInfo.next_update() == :never
    assert Process.whereis(:tzdata_release_updater) == nil

    assert {:ok,
            %DateTime{
              year: 2026,
              month: 9,
              day: 29,
              hour: 7,
              minute: 0,
              second: 0,
              time_zone: "America/Chicago",
              zone_abbr: "CDT",
              utc_offset: -21_600,
              std_offset: 3_600
            }} =
             DateTime.shift_zone(
               ~U[2026-09-29 12:00:00Z],
               "America/Chicago",
               TimeZoneInfo.TimeZoneDatabase
             )
  end
end
