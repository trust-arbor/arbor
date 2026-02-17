defmodule Arbor.Actions.Eval do
  @moduledoc """
  Evaluation operations as Jido actions.

  This module provides Jido-compatible actions for running code quality checks
  and querying past eval runs. Actions wrap the underlying `Arbor.Eval` and
  `Arbor.Orchestrator.Eval.PersistenceBridge` APIs via runtime bridges.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Check` | Run code quality checks on code or files |
  | `ListRuns` | Query past eval runs with filters |
  | `GetRun` | Get a specific eval run with results |

  ## Architecture

  Uses runtime bridges (`Code.ensure_loaded?` + `apply/3`) since both
  `arbor_eval` and `arbor_orchestrator` are Standalone apps.

  ## Examples

      # Check code quality
      {:ok, result} = Arbor.Actions.Eval.Check.run(
        %{code: "defmodule Foo do\\n  def bar, do: :ok\\nend"},
        %{}
      )

      # List recent eval runs
      {:ok, result} = Arbor.Actions.Eval.ListRuns.run(%{limit: 10}, %{})

      # Get a specific run
      {:ok, result} = Arbor.Actions.Eval.GetRun.run(%{run_id: "abc-123"}, %{})

  ## Authorization

  - Check: `arbor://actions/execute/eval.check`
  - ListRuns: `arbor://actions/execute/eval.list`
  - GetRun: `arbor://actions/execute/eval.get`
  """

  alias Arbor.Common.SafePath

  @eval_mod Arbor.Eval
  @persistence_bridge Arbor.Orchestrator.Eval.PersistenceBridge

  defmodule Check do
    @moduledoc """
    Run code quality checks on code or files.

    Uses `Arbor.Eval` for deterministic code analysis — idiom checks,
    documentation quality, naming conventions, PII detection.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `code` | string | no* | Code string to evaluate |
    | `file` | string | no* | File path to evaluate (SafePath validated) |
    | `checks` | list(string) | no | Specific check names to run |

    *One of `code` or `file` must be provided.

    ## Returns

    - `passed` - Whether all checks passed
    - `results` - List of individual check results
    - `violation_count` - Total violation count
    """

    use Jido.Action,
      name: "eval_check",
      description: "Run code quality checks on code or a file",
      category: "eval",
      tags: ["eval", "quality", "check", "code"],
      schema: [
        code: [
          type: :string,
          doc: "Code string to evaluate"
        ],
        file: [
          type: :string,
          doc: "File path to evaluate (SafePath validated)"
        ],
        checks: [
          type: {:list, :string},
          doc: "Specific check names to run (default: all)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Eval, as: EvalActions

    def taint_roles do
      %{
        code: :data,
        file: :control,
        checks: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{
        has_code: is_binary(params[:code]),
        has_file: is_binary(params[:file])
      })

      with {:ok, eval_context} <- EvalActions.build_eval_context(params),
           {:ok, results} <- EvalActions.run_checks(eval_context, params[:checks]) do
        all_passed = Enum.all?(results, fn r -> r.passed end)
        violation_count = results |> Enum.flat_map(& &1.violations) |> length()

        result = %{
          passed: all_passed,
          results: Enum.map(results, &summarize_result/1),
          violation_count: violation_count,
          check_count: length(results)
        }

        Actions.emit_completed(__MODULE__, %{
          passed: all_passed,
          violation_count: violation_count,
          check_count: length(results)
        })

        {:ok, result}
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{reason: inspect(reason)})
          error
      end
    end

    defp summarize_result(r) do
      %{
        name: r.name,
        category: r.category,
        passed: r.passed,
        violations: r.violations,
        suggestions: r.suggestions
      }
    end
  end

  defmodule ListRuns do
    @moduledoc """
    Query past eval runs with optional filters.

    Lists eval runs from the persistence layer (Postgres if available,
    JSON file fallback otherwise).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `limit` | non_neg_integer | no | Max number of runs to return (default: 20) |
    | `domain` | string | no | Filter by evaluation domain |
    | `model` | string | no | Filter by model name |

    ## Returns

    - `runs` - List of eval run summaries
    - `count` - Number of runs returned
    """

    use Jido.Action,
      name: "eval_list",
      description: "List past eval runs with optional filters",
      category: "eval",
      tags: ["eval", "list", "query", "history"],
      schema: [
        limit: [
          type: :non_neg_integer,
          default: 20,
          doc: "Maximum number of runs to return"
        ],
        domain: [
          type: :string,
          doc: "Filter by evaluation domain"
        ],
        model: [
          type: :string,
          doc: "Filter by model name"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Eval, as: EvalActions

    def taint_roles do
      %{
        limit: :data,
        domain: :data,
        model: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{})

      filters = EvalActions.build_filters(params)

      case EvalActions.list_eval_runs(filters) do
        {:ok, runs} ->
          limited = Enum.take(runs, params[:limit] || 20)

          result = %{
            runs: Enum.map(limited, &EvalActions.summarize_run/1),
            count: length(limited)
          }

          Actions.emit_completed(__MODULE__, %{count: result.count})
          {:ok, result}

        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{reason: inspect(reason)})
          error
      end
    end
  end

  defmodule GetRun do
    @moduledoc """
    Get a specific eval run with its results.

    Retrieves full details of an eval run including all result records.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `run_id` | string | yes | The eval run ID |

    ## Returns

    - `run` - The eval run record
    - `found` - Whether the run was found
    """

    use Jido.Action,
      name: "eval_get",
      description: "Get a specific eval run with results",
      category: "eval",
      tags: ["eval", "get", "query", "detail"],
      schema: [
        run_id: [
          type: :string,
          required: true,
          doc: "The eval run ID to retrieve"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Eval, as: EvalActions

    def taint_roles do
      %{
        run_id: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      run_id = params[:run_id]

      Actions.emit_started(__MODULE__, %{run_id: run_id})

      case EvalActions.get_eval_run(run_id) do
        {:ok, run_data} ->
          result = %{
            run: EvalActions.summarize_run(run_data),
            found: true
          }

          Actions.emit_completed(__MODULE__, %{run_id: run_id})
          {:ok, result}

        {:error, :not_found} ->
          {:ok, %{run: nil, found: false}}

        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{
            run_id: run_id,
            reason: inspect(reason)
          })

          error
      end
    end
  end

  # ===========================================================================
  # Shared Helpers
  # ===========================================================================

  @doc false
  def build_eval_context(params) do
    cond do
      is_binary(params[:code]) and params[:code] != "" ->
        {:ok, %{code: params[:code]}}

      is_binary(params[:file]) and params[:file] != "" ->
        project_root = File.cwd!()

        case SafePath.resolve_within(params[:file], project_root) do
          {:ok, safe_path} ->
            case File.read(safe_path) do
              {:ok, code} -> {:ok, %{code: code, file: safe_path}}
              {:error, reason} -> {:error, {:file_read_failed, safe_path, reason}}
            end

          {:error, reason} ->
            {:error, {:invalid_path, params[:file], reason}}
        end

      true ->
        {:error, :code_or_file_required}
    end
  end

  @doc false
  def run_checks(eval_context, check_names) do
    if Code.ensure_loaded?(@eval_mod) do
      try do
        checks = resolve_checks(check_names)

        case apply(@eval_mod, :run_all, [checks, eval_context]) do
          {:ok, results} -> {:ok, results}
          {:error, _} = error -> error
        end
      catch
        :exit, reason -> {:error, {:eval_unavailable, reason}}
      end
    else
      {:error, :eval_not_available}
    end
  end

  @doc false
  def list_eval_runs(filters) do
    if Code.ensure_loaded?(@persistence_bridge) do
      try do
        apply(@persistence_bridge, :list_runs, [filters])
      catch
        :exit, reason -> {:error, {:persistence_unavailable, reason}}
      end
    else
      {:error, :eval_persistence_not_available}
    end
  end

  @doc false
  def get_eval_run(run_id) do
    if Code.ensure_loaded?(@persistence_bridge) do
      try do
        apply(@persistence_bridge, :get_run, [run_id])
      catch
        :exit, reason -> {:error, {:persistence_unavailable, reason}}
      end
    else
      {:error, :eval_persistence_not_available}
    end
  end

  @doc false
  def build_filters(params) do
    filters = []

    filters =
      if params[:domain], do: Keyword.put(filters, :domain, params[:domain]), else: filters

    if params[:model], do: Keyword.put(filters, :model, params[:model]), else: filters
  end

  @doc false
  def summarize_run(run) when is_map(run) do
    # Handle both struct and plain map forms
    %{
      id: Map.get(run, :id) || Map.get(run, "id"),
      model: Map.get(run, :model) || Map.get(run, "model"),
      domain: Map.get(run, :domain) || Map.get(run, "domain"),
      status: Map.get(run, :status) || Map.get(run, "status"),
      metrics: Map.get(run, :metrics) || Map.get(run, "metrics"),
      sample_count: Map.get(run, :sample_count) || Map.get(run, "sample_count"),
      duration_ms: Map.get(run, :duration_ms) || Map.get(run, "duration_ms"),
      inserted_at: Map.get(run, :inserted_at) || Map.get(run, "inserted_at")
    }
  end

  def summarize_run(other), do: other

  # Resolve check names to modules
  defp resolve_checks(nil), do: all_checks()
  defp resolve_checks([]), do: all_checks()

  defp resolve_checks(names) when is_list(names) do
    check_map = check_name_map()

    names
    |> Enum.flat_map(fn name ->
      case Map.get(check_map, name) do
        nil -> []
        mod -> [mod]
      end
    end)
    |> case do
      [] -> all_checks()
      mods -> mods
    end
  end

  defp all_checks do
    [
      Arbor.Eval.Checks.ElixirIdioms,
      Arbor.Eval.Checks.Documentation,
      Arbor.Eval.Checks.NamingConventions,
      Arbor.Eval.Checks.PiiDetection
    ]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp check_name_map do
    %{
      "elixir_idioms" => Arbor.Eval.Checks.ElixirIdioms,
      "documentation" => Arbor.Eval.Checks.Documentation,
      "naming_conventions" => Arbor.Eval.Checks.NamingConventions,
      "pii_detection" => Arbor.Eval.Checks.PiiDetection
    }
  end
end
