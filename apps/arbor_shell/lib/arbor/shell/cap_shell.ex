defmodule Arbor.Shell.CapShell do
  @moduledoc """
  Capability-checked **compound** shell execution (PROTOTYPE).

  Where `Arbor.Shell.authorize_and_execute/3` authorizes a *single* command and
  the sandbox hard-rejects any compound command (pipes, `&&`, `$(…)`,
  redirection — see `Arbor.Shell.Sandbox`), `CapShell` runs compound commands
  *safely* by parsing and executing them in one engine (the `bash` library —
  a pure-Elixir bash parser+interpreter) with a capability-derived policy.

  ## Why this is safe

  The library parses AND executes (no parse-vs-execute gap — what we authorize is
  what runs), and its `Bash.CommandPolicy` is consulted for **every** command and
  **every** filesystem path, including inside pipes, command substitution
  (`$(…)`), and redirections — and is **immutable** (the running script cannot
  disable it). We wire that policy to Arbor's capability system:

  - **commands** → `Arbor.Shell.CapPolicy` allowlist (`arbor://shell/exec/*`),
    minus an absolute dangerous-command floor a grant does not override. Builtins
    (`echo`, `cd`, …) are allowed (they don't exec host binaries). The check is a
    dynamic function, so it runs in-process against live `CapPolicy` — no IPC.
  - **paths** → `Arbor.Security.FileGuard` (`arbor://fs/read|write/*`), so a
    redirect/read is allowed only within the agent's fs capabilities.

  ## Status / limitations (prototype)

  - The library's `paths` policy callback is arity-1 (path only, no read/write
    operation), so the fs check here is coarse: a path is allowed if the agent
    holds *any* fs capability (read or write) covering it. Finer read/write
    granularity would need the operation at this layer (a candidate upstream
    improvement).
  - Not yet wired into `authorize_and_execute/3`; this is a standalone entry point
    to validate the approach end-to-end (see
    `.arbor/decisions/2026-06-30-cap-checked-compound-shell.md`).
  - The library is pre-1.0 (pinned); its correctness is part of the security
    boundary, so the test suite carries adversarial bypass cases.
  """

  alias Arbor.Shell.CapPolicy

  require Logger

  # Absolute denylist — commands never allowed regardless of capability grant
  # (parity with Arbor.Shell.Sandbox's dangerous-command floor; the floor is the
  # hard boundary a cap grant does not lift).
  @absolute_deny ~w[rm rmdir sudo doas su shutdown reboot halt poweroff mkfs dd]

  @type result :: %{
          success?: boolean(),
          exit_code: integer() | nil,
          stdout: String.t(),
          stderr: String.t()
        }

  @doc """
  Parse and run a (possibly compound) shell command for `agent_id`, with every
  command and filesystem path capability-checked.

  Returns `{:ok, result}` where `result` carries stdout/stderr/exit_code — a
  denied command surfaces as a non-zero exit + a `"command not allowed"` stderr
  (the advisory the agent sees), not a crash. Returns `{:error, {:parse_error,
  message}}` for unparseable input.
  """
  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, {:parse_error, String.t()}}
  def run(agent_id, command, opts \\ []) when is_binary(agent_id) and is_binary(command) do
    allowlist = CapPolicy.allowlist_for(agent_id)

    command_policy = [
      commands: command_fn(allowlist),
      paths: path_fn(agent_id, opts)
    ]

    case Bash.run(command, command_policy: command_policy) do
      {:error, %{command: "parse"} = parse_result, _session} ->
        {:error, {:parse_error, parse_error_message(parse_result)}}

      {_status, _result, _session} = run_result ->
        {:ok,
         %{
           success?: Bash.success?(run_result),
           exit_code: Bash.exit_code(run_result),
           stdout: Bash.stdout(run_result),
           stderr: Bash.stderr(run_result)
         }}
    end
  end

  # Per-command capability check (dynamic, in-process). Builtins are always
  # allowed (no host binary). Externals/functions/interop must be in the agent's
  # cap-derived allowlist AND not in the absolute floor.
  defp command_fn(allowlist) do
    fn name, category ->
      base = Path.basename(name)

      cond do
        category == :builtin -> true
        base in @absolute_deny -> false
        true -> CapPolicy.allows?(allowlist, base)
      end
    end
  end

  # Per-path capability check via FileGuard. Coarse (read OR write) because the
  # library's paths callback does not carry the operation. An explicit
  # `opts[:paths]` (a `(path -> boolean)` fun) overrides — useful for testing the
  # seam without a full fs-capability setup. Fails closed.
  defp path_fn(agent_id, opts) do
    case Keyword.get(opts, :paths) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        fn path ->
          guard = Arbor.Security.FileGuard
          guard.can?(agent_id, path, :read) or guard.can?(agent_id, path, :write)
        end
    end
  end

  defp parse_error_message(%{error: msg}) when is_binary(msg), do: msg
  defp parse_error_message(other), do: inspect(other)
end
