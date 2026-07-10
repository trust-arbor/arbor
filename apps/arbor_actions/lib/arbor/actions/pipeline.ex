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

      # Run from file (requires verified AuthContext + fs/read for the resolved path)
      {:ok, result} = Arbor.Actions.Pipeline.Run.run(
        %{source_file: "specs/pipelines/research-codebase.dot"},
        %{auth_context: verified_ctx, workdir: workdir, caller_id: caller_id}
      )

  ## Authorization

  - Run: `arbor://action/pipeline/run`
  - Validate: `arbor://action/pipeline/validate`
  - `source_file` additionally requires execution-principal `arbor://fs/read`
    for the exact path resolved inside the trusted workdir, plus an independent
    caller capability for that exact normalized resource when caller ≠ executor.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.AuthContext

  @orchestrator_mod Arbor.Orchestrator
  @fs_read_resource "arbor://fs/read"

  defmodule Run do
    @moduledoc """
    Execute a DOT pipeline via the orchestrator engine.

    Accepts either a DOT source string or a path to a `.dot` file.
    File paths are resolved inside the trusted workdir and authorized via
    `arbor://fs/read` before the file is read.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `source` | string | no* | DOT source string |
    | `source_file` | string | no* | Path to a .dot file (workdir-resolved + fs/read) |
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
          doc: "Path to a .dot file (resolved in trusted workdir; requires fs/read)"
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
           {:ok, dot_source} <- Pipeline.resolve_source(params, authority),
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

    Inline `source` is governed only by the action's pipeline/validate gate.
    `source_file` additionally requires verified fs/read authority for the
    resolved path (without requiring pipeline/run authority).

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
          doc: "Path to a .dot file (resolved in trusted workdir; requires fs/read)"
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
    def run(params, context) do
      Actions.emit_started(__MODULE__, %{})

      with {:ok, authority} <- Pipeline.verified_source_authority(params, context),
           {:ok, dot_source} <- Pipeline.resolve_source(params, authority),
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
  # Fail-closed: source_file without verified authority must never read.
  def resolve_source(%{source: source}) when is_binary(source) and source != "" do
    {:ok, source}
  end

  def resolve_source(%{source_file: path}) when is_binary(path) and path != "" do
    {:error, :verified_source_file_authority_required}
  end

  def resolve_source(_params) do
    {:error, :source_or_source_file_required}
  end

  @doc false
  def resolve_source(%{source: source}, _authority) when is_binary(source) and source != "" do
    {:ok, source}
  end

  def resolve_source(%{source_file: path}, authority)
      when is_binary(path) and path != "" and is_map(authority) do
    workdir = Map.get(authority, :workdir)

    if is_binary(workdir) and workdir != "" do
      case SafePath.resolve_within(path, workdir) do
        {:ok, safe_path} ->
          with :ok <- authorize_source_file_read(authority, safe_path) do
            case File.read(safe_path) do
              {:ok, content} -> {:ok, content}
              {:error, reason} -> {:error, {:file_read_failed, safe_path, reason}}
            end
          end

        {:error, reason} ->
          {:error, {:invalid_path, path, reason}}
      end
    else
      {:error, :trusted_workdir_required}
    end
  end

  def resolve_source(%{source_file: path}, _authority) when is_binary(path) and path != "" do
    {:error, :verified_source_file_authority_required}
  end

  def resolve_source(_params, _authority), do: {:error, :source_or_source_file_required}

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

    with %AuthContext{
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

  @doc false
  # Authority for reading/validating source. Inline source needs no file authority.
  # source_file requires verified AuthContext + trusted workdir + signer, but does
  # NOT require pipeline/run capability (Validate must not gain run authority).
  def verified_source_authority(params, context) when is_map(params) and is_map(context) do
    cond do
      present_source?(params[:source] || params["source"]) ->
        {:ok, :inline}

      present_source?(params[:source_file] || params["source_file"]) ->
        verified_file_read_authority(context)

      true ->
        {:error, :source_or_source_file_required}
    end
  end

  def verified_source_authority(_params, _context), do: {:error, :source_or_source_file_required}

  defp present_source?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_source?(_), do: false

  defp verified_file_read_authority(context) when is_map(context) do
    auth_context = Map.get(context, :auth_context) || Map.get(context, "auth_context")

    with %AuthContext{
           identity_verified: true,
           principal_id: raw_principal,
           signer: signer
         } = auth <- auth_context,
         {:ok, principal} <- validate_id(raw_principal),
         true <- is_function(signer, 1),
         {:ok, workdir} <- trusted_workdir(context),
         {:ok, caller_id} <- context_id(context, :caller_id, principal),
         {:ok, task_id} <- context_id(context, :task_id, nil),
         {:ok, session_id} <- context_id(context, :session_id, auth.session_id) do
      {:ok,
       %{
         execution_principal: principal,
         caller_id: caller_id,
         task_id: task_id,
         session_id: session_id,
         signer: signer,
         workdir: workdir
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :verified_source_file_authority_required}
    end
  end

  defp authorize_source_file_read(authority, resolved_path)
       when is_map(authority) and is_binary(resolved_path) do
    scope_opts = scope_opts(authority)
    file_opts = Keyword.put(scope_opts, :file_path, resolved_path)

    with {:ok, signed_request} <- sign_fs_read(authority.signer),
         :ok <-
           authorize_execution_principal_read(authority, resolved_path, signed_request, file_opts),
         :ok <- authorize_caller_read_capability(authority, file_opts) do
      :ok
    end
  end

  defp sign_fs_read(signer) when is_function(signer, 1) do
    case signer.(@fs_read_resource) do
      {:ok, signed_request} -> {:ok, signed_request}
      {:error, reason} -> {:error, {:source_file_signing_failed, reason}}
      other -> {:error, {:source_file_signing_failed, {:invalid_signer_result, other}}}
    end
  end

  defp sign_fs_read(_), do: {:error, :verified_source_file_authority_required}

  defp authorize_execution_principal_read(authority, resolved_path, signed_request, file_opts) do
    # Parent action already verified AuthContext identity. Re-sign for the nested
    # arbor://fs/read resource (pipeline nonce/resource cannot be reused), then
    # authorize with identity_verified so AuthDecision does not re-verify the
    # parent proof or treat the synthetic principal as unknown.
    auth_opts =
      file_opts
      |> Keyword.put(:signed_request, signed_request)
      |> Keyword.put(:identity_verified, true)
      |> Keyword.put(:file_path, resolved_path)

    case Arbor.Security.authorize(
           authority.execution_principal,
           @fs_read_resource,
           :execute,
           auth_opts
         ) do
      {:ok, :authorized} ->
        :ok

      {:ok, :authorized, _path} ->
        :ok

      # Nested source-file read has no approval-wait path — fail closed.
      {:ok, :pending_approval, _proposal_id} ->
        {:error, :source_file_read_requires_approval}

      {:error, reason} ->
        {:error, {:source_file_read_denied, reason}}

      other ->
        {:error, {:source_file_read_denied, {:unexpected_authz_result, other}}}
    end
  end

  defp authorize_caller_read_capability(authority, file_opts) do
    caller_id = Map.get(authority, :caller_id)
    principal = Map.get(authority, :execution_principal)

    if caller_id in [nil, ""] or caller_id == principal do
      :ok
    else
      scope_opts = scope_opts(authority)

      with {:ok, effective_resource} <-
             Arbor.Security.normalize_authorization_resource_uri(@fs_read_resource, file_opts),
           {:ok, capabilities} <- Arbor.Security.list_capabilities(caller_id, scope_opts),
           true <-
             Enum.any?(capabilities, fn capability ->
               Arbor.Security.capability_authorizes?(capability, effective_resource, scope_opts)
             end) do
        :ok
      else
        {:error, reason} -> {:error, {:caller_source_file_authority_missing, reason}}
        _ -> {:error, :caller_source_file_authority_missing}
      end
    end
  end

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

  defp scope_opts(authority) when is_map(authority) do
    []
    |> maybe_put_opt(:task_id, Map.get(authority, :task_id))
    |> maybe_put_opt(:session_id, Map.get(authority, :session_id))
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
