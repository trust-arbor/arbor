defmodule Arbor.Shell.SpawnCapableArgvLimits do
  @moduledoc """
  Pure system ceilings for spawn-capable command arguments.

  This is the Shell-owned source of truth consumed by both Apple Container
  request cores. Higher libraries read the bounds only through the public
  `Arbor.Shell` facade.
  """

  @max_command_args 256
  @max_command_arg_bytes 4_096

  @doc "Maximum number of command arguments admitted for one execution."
  @spec max_command_args() :: pos_integer()
  def max_command_args, do: @max_command_args

  @doc "Maximum UTF-8 byte size admitted for one command argument."
  @spec max_command_arg_bytes() :: pos_integer()
  def max_command_arg_bytes, do: @max_command_arg_bytes
end
