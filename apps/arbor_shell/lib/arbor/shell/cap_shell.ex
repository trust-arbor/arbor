defmodule Arbor.Shell.CapShell do
  @moduledoc """
  Fail-closed compound-shell boundary (intentionally unavailable).

  ## Intentional security API break

  CapShell previously attempted capability-checked **compound** shell execution
  (pipes, `&&`/`||`/`;`, substitution, redirection) via the pinned `bash`
  library and a `Bash.CommandPolicy` wired to Arbor capabilities. That prototype
  is **retired as an execution path**.

  Root-cause analysis against pinned Bash/ExCmd confirmed it cannot currently
  satisfy Arbor's product-level fail-closed capability and resource guarantees:

  1. **`Bash.CommandPolicy` sees command name/category but not argv** — dynamic
     expansion and opaque wrappers can bypass dangerous flag/command semantics.
  2. **`Bash.Session.new` is a synchronous creation boundary** without the
     cancellation contract Arbor needs for bounded admission.
  3. **Foreground, background, and coprocess branches have different owners** —
     Session death is not a uniform process-tree proof.
  4. **Static AST admission cannot prove runtime-expanded argv** — what is
     authorized at parse time is not what may execute after expansion.

  Therefore every public CapShell execution entry returns the stable error
  `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}`
  **before** parsing, `Bash.Session` creation, external process launch,
  filesystem access, or adapter dispatch — including malformed terms/options.
  There is no silent fallback to an unchecked shell or to the bounded
  single-command executor.

  Configuration (`:arbor_shell, :compound_shell_enabled`) defaults to `false`
  and **cannot re-enable** this prototype when set `true` — operators who opt
  in still receive the same unavailable error (see `Arbor.Shell`).

  ## Missing upstream contracts (required before any re-enable)

  Any future compound-shell path must obtain, at minimum:

  - **argv-aware runtime policy after expansion** — policy must observe the
    final command name *and* argv after shell expansion, not only the static
    AST name/category.
  - **bounded / cancelable session creation and receipt** — session admission
    and output collection must honor absolute wall-clock deadlines and
    retained-output ceilings with a cancelable control plane (not
    post-truncation after unbounded collection).
  - **deterministic ownership / termination for every admitted branch** —
    foreground, background, and coprocess work must share a uniform process-tree
    ownership proof so Session death terminates all admitted descendants.

  Until those contracts exist upstream (or Arbor owns an equivalent runtime),
  CapShell remains this small, auditable fail-closed stub. Ordinary
  non-compound execution continues via `Arbor.Shell.Executor` /
  `Arbor.Shell.execute/2` unchanged.
  """

  @unavailable_reason {:compound_shell_unavailable, :security_boundary_incomplete}

  @doc """
  Fail closed: compound shell execution is intentionally unavailable.

  Does not parse input, create a `Bash.Session`, launch processes, touch the
  filesystem, or dispatch to any shell adapter. Always returns
  `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}`.

  Accepts any terms (including malformed agent_id/command/opts) and never
  raises — callers must not observe a `FunctionClauseError` as a bypass or
  crash side channel.

  This is an intentional security API break for the retired CapShell prototype —
  there is no override or test hook that re-enables execution.
  """
  @spec run(term(), term(), term()) ::
          {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  def run(agent_id \\ nil, command \\ nil, opts \\ [])

  def run(_agent_id, _command, _opts) do
    # Fail closed before any parse / Session / process / fs / adapter work.
    # Arguments are accepted for call-site compatibility only and are ignored.
    {:error, @unavailable_reason}
  end
end
