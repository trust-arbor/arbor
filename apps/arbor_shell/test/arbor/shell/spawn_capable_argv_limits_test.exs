defmodule Arbor.Shell.SpawnCapableArgvLimitsTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.SpawnCapableArgvLimits

  @moduletag :fast

  test "public facade exposes the Shell-owned closed argv ceilings" do
    assert Shell.spawn_capable_max_command_args() ==
             SpawnCapableArgvLimits.max_command_args()

    assert Shell.spawn_capable_max_command_arg_bytes() ==
             SpawnCapableArgvLimits.max_command_arg_bytes()

    assert Shell.spawn_capable_max_command_args() == 256
    assert Shell.spawn_capable_max_command_arg_bytes() == 4_096
  end
end
