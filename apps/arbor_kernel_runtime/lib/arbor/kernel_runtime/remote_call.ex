defmodule Arbor.KernelRuntime.RemoteCall do
  @moduledoc """
  Server-side entry point for `mix arbor.*` RPCs.

  `:rpc.call/4` runs the remote function in a process whose group leader is
  the CALLER's — the operator's `mix` shell. Elixir's console logger writes
  events whose group leader lives on another node to that group leader, so
  every `Logger` line the server emitted while serving the call (query
  logs, `[info]` progress, warnings from unrelated processes that happened
  to run under the same leader) was echoed onto the operator's terminal.
  On a fresh install `mix arbor.user.init` printed ~100 raw SQL statements
  around its four real lines of output.

  `apply_quiet/3` re-parents the RPC process to the server's own `:user`
  before applying, so its logs stay in the server log where they belong.
  The task still gets the return value; it never needed the server's IO.
  """

  @spec apply_quiet(module(), atom(), [term()]) :: term()
  def apply_quiet(mod, fun, args) when is_atom(mod) and is_atom(fun) and is_list(args) do
    case Process.whereis(:user) do
      pid when is_pid(pid) -> Process.group_leader(self(), pid)
      _ -> :ok
    end

    apply(mod, fun, args)
  end
end
