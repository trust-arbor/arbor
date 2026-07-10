defmodule Arbor.Actions.Pipeline do
  @moduledoc """
  DOT pipeline orchestration operations as Jido actions.

  This module provides Jido-compatible actions for running and validating
  DOT orchestrator pipelines. Actions wrap the underlying `Arbor.Orchestrator`
  API via runtime bridge (orchestrator is a Standalone app).

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Run` | Execute a DOT pipeline and return results |
  | `Validate` | Validate a DOT pipeline without executing |

  ## Architecture

  Uses runtime bridge (`Code.ensure_loaded?` + `apply/3`) to call
  `Arbor.Orchestrator` without compile-time dependency, respecting the
  library hierarchy (arbor_actions is Level 2, arbor_orchestrator is Standalone).

  ## Examples

      # Run from source string
      {:ok, result} = Arbor.Actions.Pipeline.Run.run(
        %{source: ~s(digraph { start [type="start"] done [type="exit"] start -> done })},
        %{}
      )

      # Run from file
      {:ok, result} = Arbor.Actions.Pipeline.Run.run(
        %{source_file: "specs/pipelines/research-codebase.dot"},
        %{}
      )

  ## Authorization

  - Run: `arbor://action/pipeline/run`
  - Validate: `arbor://action/pipeline/validate`
  """

  alias Arbor.Common.SafePath

  @orchestrator_mod Arbor.Orchestrator

  defmodule Run do
    @moduledoc """
    Execute a DOT pipeline via the orchestrator engine.

    Accepts either a DOT source string or a path to a `.dot` file.
    File paths are validated via SafePath to prevent path traversal.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `source` | string | no* | DOT source string |
    | `source_file` | string | no* | Path to a .dot file (SafePath validated) |
    | `initial_context` | map | no | Initial context values for the pipeline |

    *One of `source` or `source_file` must be provided.

    ## Returns

    - `status` - Pipeline execution status (:success or :error)
    - `context` - Final pipeline context after execution
    - `nodes_executed` - Number of nodes that were executed
    """

    use Jido.Action,
      name: "pipeline_run",
      description: "Execute a DOT orchestrator pipeline",
      category: "pipeline",
      tags: ["pipeline", "orchestrator", "dot", "execution"],
      schema: [
        source: [
          type: :string,
          doc: "DOT source string to execute"
        ],
        source_file: [
          type: :string,
          doc: "Path to a .dot file (SafePath validated)"
        ],
        initial_context: [
          type: :map,
          default: %{},
          doc: "Initial context values for the pipeline"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Pipeline

    def taint_roles do
      %{
        source: :control,
        source_file: :control,
        initial_context: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, %{
        has_source: is_binary(params[:source]),
        has_source_file: is_binary(params[:source_file])
      })

      start_time = System.monotonic_time(:millisecond)

      with {:ok, authority} <- Pipeline.verified_run_authority(context),
           {:ok, dot_source} <- Pipeline.resolve_source(params, authority.workdir),
           {:ok, engine_result} <- Pipeline.run_pipeline(dot_source, params, authority) do
        duration_ms = System.monotonic_time(:millisecond) - start_time

        status = extract_status(engine_result)
        completed = Map.get(engine_result, :completed_nodes, [])

        result = %{
          status: status,
          context: sanitize_context(engine_result),
          nodes_executed: length(completed),
          completed_nodes: completed,
          duration_ms: duration_ms
        }

        Actions.emit_completed(__MODULE__, %{
          status: status,
          nodes_executed: result.nodes_executed,
          duration_ms: duration_ms
        })

        {:ok, result}
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{reason: inspect(reason)})
          error
      end
    end

    # @doc false — public for testability (the H4 security regression test
    # asserts an unknown outcome string maps to :unknown via SafeAtom and is
    # NOT minted as a new atom). The orchestrator-driven public path
    # (Pipeline.Run.run/2) can't run in arbor_actions' own test BEAM
    # (arbor_orchestrator isn't loaded), so the call site is exercised directly.
    @doc false
    def extract_status(%{final_outcome: %{status: status}}), do: status

    def extract_status(%{context: %{"outcome" => outcome}}) do
      case Arbor.Common.SafeAtom.to_allowed(outcome, ~w(success failure error pending cancelled)a) do
        {:ok, status} -> status
        {:error, _} -> :unknown
      end
    end

    def extract_status(_), do: :unknown

    defp sanitize_context(engine_result) do
      # Extract serializable context, dropping internal state
      case engine_result do
        %{context: %{values: values}} when is_map(values) -> values
        %{context: ctx} when is_map(ctx) -> ctx
        _ -> %{}
      end
    end
  end

  defmodule Validate do
    @moduledoc """
    Validate a DOT pipeline without executing it.

    Returns diagnostics (errors, warnings) about the pipeline structure.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `source` | string | no* | DOT source string |
    | `source_file` | string | no* | Path to a .dot file |

    *One of `source` or `source_file` must be provided.

    ## Returns

    - `valid` - Whether the pipeline is valid (no errors)
    - `diagnostics` - List of diagnostic messages
    - `error_count` - Number of errors
    - `warning_count` - Number of warnings
    """

    use Jido.Action,
      name: "pipeline_validate",
      description: "Validate a DOT orchestrator pipeline without executing",
      category: "pipeline",
      tags: ["pipeline", "orchestrator", "dot", "validation"],
      schema: [
        source: [
          type: :string,
          doc: "DOT source string to validate"
        ],
        source_file: [
          type: :string,
          doc: "Path to a .dot file (SafePath validated)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Pipeline

    def taint_roles do
      %{
        source: :control,
        source_file: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{})

      with {:ok, dot_source} <- Pipeline.resolve_source(params),
           {:ok, diagnostics} <- Pipeline.validate_pipeline(dot_source) do
        errors = Enum.count(diagnostics, &(&1.severity == :error))
        warnings = Enum.count(diagnostics, &(&1.severity == :warning))

        result = %{
          valid: errors == 0,
          diagnostics: Enum.map(diagnostics, &format_diagnostic/1),
          error_count: errors,
          warning_count: warnings
        }

        Actions.emit_completed(__MODULE__, %{
          valid: result.valid,
          error_count: errors,
          warning_count: warnings
        })

        {:ok, result}
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{reason: inspect(reason)})
          error
      end
    end

    defp format_diagnostic(diag) do
      %{
        severity: diag.severity,
        node: Map.get(diag, :node_id, nil),
        message: diag.message
      }
    end
  end

  # ===========================================================================
  # Shared Helpers
  # ===========================================================================

  @doc false
  def resolve_source(%{source: source}) when is_binary(source) and source != "" do
    {:ok, source}
  end

  def resolve_source(%{source_file: path}) when is_binary(path) and path != "" do
    # Validate path stays within project root
    project_root = File.cwd!()

    case SafePath.resolve_within(path, project_root) do
      {:ok, safe_path} ->
        case File.read(safe_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:file_read_failed, safe_path, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_path, path, reason}}
    end
  end

  def resolve_source(_params) do
    {:error, :source_or_source_file_required}
  end

  @doc false
  def resolve_source(%{source: source}, _workdir) when is_binary(source) and source != "" do
    {:ok, source}
  end

  def resolve_source(%{source_file: path}, workdir)
      when is_binary(path) and path != "" and is_binary(workdir) do
    case SafePath.resolve_within(path, workdir) do
      {:ok, safe_path} ->
        case File.read(safe_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:file_read_failed, safe_path, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_path, path, reason}}
    end
  end

  def resolve_source(_params, _workdir), do: {:error, :source_or_source_file_required}

  @doc false
  def run_pipeline(dot_source, params, authority) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      opts = build_opts(params, authority)

      try do
        apply(@orchestrator_mod, :run_as, [
          dot_source,
          authority.execution_principal,
          authority.signer,
          opts
        ])
      catch
        :exit, reason -> {:error, {:orchestrator_unavailable, reason}}
      end
    else
      {:error, :orchestrator_not_available}
    end
  end

  def run_pipeline(_dot_source, _params), do: {:error, :verified_run_authority_required}

  @doc false
  def validate_pipeline(dot_source) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      try do
        diagnostics = apply(@orchestrator_mod, :validate, [dot_source])
        {:ok, diagnostics}
      catch
        :exit, reason -> {:error, {:orchestrator_unavailable, reason}}
      end
    else
      {:error, :orchestrator_not_available}
    end
  end

  @doc false
  def verified_run_authority(context) when is_map(context) do
    auth_context = Map.get(context, :auth_context) || Map.get(context, "auth_context")

    with %Arbor.Contracts.Security.AuthContext{
           identity_verified: true,
           principal_id: raw_principal,
           signer: signer
         } = auth <- auth_context,
         {:ok, principal} <- validate_id(raw_principal),
         true <- is_function(signer, 1),
         {:ok, workdir} <- trusted_workdir(context),
         {:ok, caller_id} <- context_id(context, :caller_id, principal),
         {:ok, author_id} <- context_id(context, :author_id, caller_id),
         {:ok, task_id} <- context_id(context, :task_id, nil),
         {:ok, session_id} <- context_id(context, :session_id, auth.session_id),
         :ok <- verify_caller_run_capability(caller_id, task_id, session_id) do
      {:ok,
       %{
         execution_principal: principal,
         caller_id: caller_id,
         author_id: author_id,
         task_id: task_id,
         session_id: session_id,
         signer: signer,
         workdir: workdir
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :verified_run_authority_required}
    end
  end

  def verified_run_authority(_context), do: {:error, :verified_run_authority_required}

  defp build_opts(params, authority) do
    initial_values =
      case params[:initial_context] do
        ctx when is_map(ctx) ->
          Map.drop(ctx, [
            :agent_id,
            :caller_id,
            :task_id,
            :session_id,
            :workdir,
            "session.agent_id",
            "session.caller_id",
            "session.task_id",
            "session.session_id",
            "workdir"
          ])

        _ ->
          %{}
      end

    [
      initial_values: initial_values,
      caller_id: authority.caller_id,
      author_id: authority.author_id,
      workdir: authority.workdir
    ]
    |> maybe_put_opt(:task_id, authority.task_id)
    |> maybe_put_opt(:session_id, authority.session_id)
  end

  defp verify_caller_run_capability(caller_id, task_id, session_id) do
    scope_opts = [] |> maybe_put_opt(:task_id, task_id) |> maybe_put_opt(:session_id, session_id)

    with {:ok, capabilities} <- Arbor.Security.list_capabilities(caller_id, scope_opts),
         true <-
           Enum.any?(capabilities, fn capability ->
             Arbor.Security.capability_authorizes?(
               capability,
               "arbor://action/pipeline/run",
               scope_opts
             )
           end) do
      :ok
    else
      _ -> {:error, :caller_pipeline_run_authority_missing}
    end
  end

  defp trusted_workdir(context) do
    case Map.get(context, :workdir) || Map.get(context, "workdir") do
      workdir when is_binary(workdir) ->
        trimmed = String.trim(workdir)

        if trimmed != "" and String.valid?(trimmed) and not String.contains?(trimmed, <<0>>),
          do: {:ok, Path.expand(trimmed)},
          else: {:error, :trusted_workdir_required}

      _ ->
        {:error, :trusted_workdir_required}
    end
  end

  defp context_id(context, key, default) do
    value = Map.get(context, key) || Map.get(context, to_string(key)) || default

    case value do
      nil -> {:ok, nil}
      value -> validate_id(value)
    end
  end

  defp validate_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.valid?(trimmed) and not String.contains?(trimmed, <<0>>),
      do: {:ok, trimmed},
      else: {:error, :invalid_run_authority_id}
  end

  defp validate_id(_value), do: {:error, :invalid_run_authority_id}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
