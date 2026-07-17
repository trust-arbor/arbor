defmodule Arbor.Shell.SpawnCapableTimeout do
  @moduledoc """
  Pure system ceiling for spawn-capable execution wall-clock timeouts.

  Single Shell-owned source of truth for the maximum `:timeout` accepted by
  `Arbor.Shell.execute_spawn_capable/3` and the Apple Container unit admission
  path. Fail-closed: values above the ceiling are rejected without clamping.

  Higher libraries must read the bound only through the public
  `Arbor.Shell.spawn_capable_max_timeout_ms/0` facade.
  """

  @max_timeout_ms 600_000
  @max_probe_deadline_ms 300_000
  @min_timeout_ms 1

  @doc "Non-bypassable hard maximum for spawn-capable execution timeouts (ms)."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc "Hard maximum for the admission probe sub-deadline (ms)."
  @spec max_probe_deadline_ms() :: pos_integer()
  def max_probe_deadline_ms, do: @max_probe_deadline_ms

  @doc "Minimum accepted spawn-capable execution timeout (ms)."
  @spec min_timeout_ms() :: pos_integer()
  def min_timeout_ms, do: @min_timeout_ms
end
