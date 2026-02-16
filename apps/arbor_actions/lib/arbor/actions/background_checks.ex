defmodule Arbor.Actions.BackgroundChecks do
  @moduledoc """
  Background health checks for Claude Code's file-based data sources.

  Called via MCP `arbor_run` during heartbeat time to assess the health of
  personal memory, journal, project memory, session patterns, roadmap items,
  and Arbor runtime state.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Run` | Execute all background health checks and return a diagnostic report |
  """

  defmodule Run do
    @moduledoc """
    Run background health checks on Claude Code's file-based data sources.

    Performs 6 diagnostic checks on personal memory, journal continuity,
    project memory, session tool patterns, roadmap staleness, and Arbor
    runtime health. Each check is isolated via try/rescue so one failure
    cannot block others.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `skip` | list(string) | no | Check names to skip |
    | `session_dir` | string | no | Override session JSONL directory |
    | `personal_dir` | string | no | Override personal memory directory |
    | `project_dir` | string | no | Override project directory |
    | `max_sessions` | integer | no | Max recent sessions to scan (default: 3) |

    ## Returns

    - `actions` - Things that need immediate attention
    - `warnings` - Issues the agent should know about
    - `suggestions` - Informational observations
    - `markdown` - Formatted report string
    - `duration_ms` - Total check duration in milliseconds
    - `checks_run` - List of check names that ran
    - `checks_skipped` - List of check names that were skipped
    """

    use Jido.Action,
      name: "background_checks_run",
      description: "Run background health checks on Claude Code's file-based data sources",
      category: "background_checks",
      tags: ["background", "health", "diagnostics", "heartbeat"],
      schema: [
        skip: [
          type: {:list, :string},
          default: [],
          doc: "Check names to skip"
        ],
        session_dir: [
          type: :string,
          doc: "Override session JSONL directory"
        ],
        personal_dir: [
          type: :string,
          doc: "Override personal memory directory"
        ],
        project_dir: [
          type: :string,
          doc: "Override project directory"
        ],
        max_sessions: [
          type: :non_neg_integer,
          default: 3,
          doc: "Max recent sessions to scan"
        ]
      ]

    require Logger

    alias Arbor.Actions.BackgroundChecks.Run.Checks

    # ============================================================================
    # Taint Roles
    # ============================================================================

    @spec taint_roles() :: %{atom() => :data}
    def taint_roles do
      %{
        skip: :data,
        session_dir: :data,
        personal_dir: :data,
        project_dir: :data,
        max_sessions: :data
      }
    end

    # ============================================================================
    # Main Entry Point
    # ============================================================================

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      start = System.monotonic_time(:millisecond)

      personal_dir = params[:personal_dir] || Path.expand("~/.claude/arbor-personal")

      session_dir =
        params[:session_dir] ||
          Path.expand("~/.claude/projects/-Users-azmaveth-code-trust-arbor-arbor")

      project_dir = params[:project_dir] || Path.expand("~/code/trust-arbor/arbor")
      max_sessions = params[:max_sessions] || 3
      skip = params[:skip] || []

      checks = [
        {"memory_freshness", fn -> Checks.check_memory_freshness(personal_dir) end},
        {"journal_continuity", fn -> Checks.check_journal_continuity(personal_dir) end},
        {"memory_md_health", fn -> Checks.check_memory_md_health(session_dir) end},
        {"session_patterns", fn -> Checks.check_session_patterns(session_dir, max_sessions) end},
        {"roadmap_staleness", fn -> Checks.check_roadmap_staleness(project_dir) end},
        {"system_health", fn -> Checks.check_system_health() end}
      ]

      {to_run, to_skip} = Enum.split_with(checks, fn {name, _} -> name not in skip end)

      named_results =
        Enum.map(to_run, fn {name, check_fn} ->
          result =
            try do
              check_fn.()
            rescue
              e ->
                %{
                  actions: [],
                  warnings: [
                    %{
                      type: :check_error,
                      message: "Check '#{name}' failed: #{Exception.message(e)}",
                      severity: :warning,
                      data: %{check: name, error: Exception.message(e)}
                    }
                  ],
                  suggestions: []
                }
            end

          {name, result}
        end)

      merged = Checks.merge_results(Enum.map(named_results, fn {_name, result} -> result end))
      duration_ms = System.monotonic_time(:millisecond) - start

      checks_run = Enum.map(named_results, fn {name, _} -> name end)
      checks_skipped = Enum.map(to_skip, fn {name, _} -> name end)

      markdown = Checks.format_markdown(merged, named_results, duration_ms)

      {:ok,
       %{
         actions: merged.actions,
         warnings: merged.warnings,
         suggestions: merged.suggestions,
         markdown: markdown,
         duration_ms: duration_ms,
         checks_run: checks_run,
         checks_skipped: checks_skipped
       }}
    end
  end
end
