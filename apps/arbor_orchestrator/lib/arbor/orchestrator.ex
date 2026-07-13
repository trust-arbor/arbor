defmodule Arbor.Orchestrator do
  @moduledoc """
  DOT-based pipeline orchestration runtime for Arbor.

  Provides a graph-driven execution engine where pipelines are defined as
  DOT digraphs with typed handler nodes. Supports 31+ handler types
  (LLM calls, tool dispatch, consensus, memory, security, etc.) and
  12 session types for multi-turn agent interactions.

  ## Quick Start

      # Parse and run a DOT pipeline
      {:ok, result} = Arbor.Orchestrator.run(dot_source)

      # Run from a .dot file
      {:ok, result} = Arbor.Orchestrator.run_file("pipelines/my_pipeline.dot")

      # Compile for analysis (taint tracking, capability requirements)
      {:ok, compiled} = Arbor.Orchestrator.compile(dot_source)
      diagnostics = Arbor.Orchestrator.validate_typed(compiled)

  ## Architecture

      DOT source → Parser → Graph → Transforms → IR.Compiler → Compiled Graph
                                                                      ↓
                                                             Engine.run (step loop)
                                                                      ↓
                                                             Handler dispatch per node

  The engine walks the graph node-by-node, dispatching each to its typed
  handler. Handlers receive node attributes and return results that flow
  to downstream nodes via edges. Edge conditions gate transitions.

  Built-in transforms (VariableExpansion, ModelStylesheet) run BEFORE
  IR.Compiler so the compiler's static analyses (capability aggregation,
  taint profile, schema validation) read post-transform attribute values.
  Caller-supplied transforms (via `:transforms` opt) run AFTER IR.Compiler
  and cannot influence the compiler's analyses.

  ## Key Subsystems

  - **UnifiedLLM** — Provider-agnostic LLM client (14 adapters, embeddings)
  - **Sessions** — Multi-turn stateful interactions (DOT-as-session-graph)
  - **Eval** — Pipeline and agent evaluation framework
  - **IR** — Typed intermediate representation for security analysis
  """

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CodingPlan.ActionCatalog
  alias Arbor.Orchestrator.CodingPlan.Compilation
  alias Arbor.Orchestrator.CodingPlan.ExecutionManifest
  alias Arbor.Orchestrator.CodingPlan.Profiles
  alias Arbor.Orchestrator.CodingPlan.SemanticPreflight
  alias Arbor.Orchestrator.CodingTaskExecutor
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.Conformance
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.RunAuthorization
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.IR
  alias Arbor.Orchestrator.JobRegistry
  alias Arbor.Orchestrator.Transforms.ModelStylesheet
  alias Arbor.Orchestrator.Transforms.VariableExpansion
  alias Arbor.Orchestrator.Validation.Diagnostic
  alias Arbor.Orchestrator.Validation.Validator

  @type run_result :: {:ok, Engine.run_result()} | {:error, term()}
  @type run_credential :: function() | SigningAuthority.t()

  @doc "Parse a DOT source string into a Graph struct."
  @spec parse(String.t()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(dot_source) when is_binary(dot_source), do: Parser.parse(dot_source)

  @doc "Run structural validation on a DOT source or Graph, returning diagnostics."
  @spec validate(String.t() | Graph.t(), keyword()) ::
          [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate(source_or_graph, opts \\ []) do
    case ensure_graph(source_or_graph, opts) do
      {:ok, graph} ->
        Validator.validate(graph)

      {:error, reason} ->
        [
          Diagnostic.error(
            "parse_error",
            "Could not parse pipeline: #{inspect(reason)}"
          )
        ]
    end
  end

  @doc """
  Parse, compile, validate, and execute a DOT pipeline through the legacy/trusted API.

  New caller-bound execution should use `run_as/4`. This compatibility API keeps
  authorization disabled unless trusted code explicitly supplies Engine options.
  """
  @spec run(String.t() | Graph.t(), keyword()) :: run_result()
  def run(source_or_graph, opts \\ []) do
    with :ok <- reject_early_authorized_overrides(opts),
         {:ok, graph} <- ensure_graph(source_or_graph, opts),
         :ok <- Validator.validate_or_error(graph) do
      Engine.run(graph, opts)
    end
  end

  @doc """
  Securely execute a pipeline as an explicit principal.

  Accepts either a legacy 1-arity signer function or a reload-stable
  `%Arbor.Contracts.Security.SigningAuthority{}`. This function forces
  authorization on, verifies the coarse execution gate, and binds the exact
  source hash before Engine execution.

  ## Credential paths

  - **Legacy signer** — installs `:signer` + a process-local `:authorizer`
    closure (unchanged compatibility path). Rejects any present
    `:signing_authority` key in `opts` (including `nil`).
  - **SigningAuthority** — places only `:signing_authority` in trusted Engine
    opts. Does **not** synthesize a long-lived signer/authorizer closure.
    Rejects mixed legacy credential controls in `opts` (`:signer`,
    `:authorizer`, `:identity_private_key`, or a second `:signing_authority`).
    **Mixed credentials are detected by key presence, not value validity** —
    `signer: nil` or `identity_private_key: nil` still counts as mixed.
    Requires `authority.principal_id` to equal `execution_principal`.
    The gate uses the fixed `Arbor.Security` facade and always fails closed
    (never consults Config availability / required / security_module seams).
  """
  @spec run_as(String.t() | Graph.t(), String.t(), run_credential(), keyword()) :: run_result()
  def run_as(source_or_graph, execution_principal, credential, opts \\ [])

  def run_as(source_or_graph, execution_principal, %SigningAuthority{} = authority, opts)
      when is_list(opts) do
    with :ok <- validate_secure_principal(execution_principal),
         {:ok, authority} <- canonicalize_authority(authority),
         :ok <- validate_authority_principal(authority, execution_principal),
         :ok <- reject_mixed_authority_credentials(opts),
         :ok <- validate_principal_opt(opts, execution_principal),
         {:ok, opts} <- bind_secure_graph_hash(source_or_graph, opts),
         :ok <-
           Arbor.Orchestrator.Authorization.check_orchestrator_access(
             execution_principal,
             authority
           ) do
      # Authority path: process-local opaque reference only — no signer/authorizer
      # closures and no extractable identity_private_key.
      secure_opts =
        opts
        |> Keyword.drop([:signer, :authorizer, :identity_private_key, :signing_authority])
        |> Keyword.put(:authorization, true)
        |> Keyword.put(:execution_principal, execution_principal)
        |> Keyword.put(:agent_id, execution_principal)
        |> Keyword.put(:signing_authority, authority)

      run(source_or_graph, secure_opts)
    end
  end

  def run_as(source_or_graph, execution_principal, signer, opts)
      when is_function(signer, 1) and is_list(opts) do
    with :ok <- validate_secure_principal(execution_principal),
         :ok <- validate_secure_signer(signer),
         :ok <- reject_signing_authority_in_legacy_opts(opts),
         :ok <- validate_principal_opt(opts, execution_principal),
         {:ok, opts} <- bind_secure_graph_hash(source_or_graph, opts),
         :ok <-
           Arbor.Orchestrator.Authorization.check_orchestrator_access(
             execution_principal,
             signer
           ) do
      secure_opts =
        opts
        |> Keyword.put(:authorization, true)
        |> Keyword.put(:execution_principal, execution_principal)
        |> Keyword.put(:agent_id, execution_principal)
        |> Keyword.put(:signer, signer)
        |> Keyword.put(:authorizer, secure_authorizer(execution_principal, signer))

      run(source_or_graph, secure_opts)
    end
  end

  def run_as(_source_or_graph, _execution_principal, _credential, _opts) do
    {:error, :invalid_run_credential}
  end

  @doc "Read and execute a .dot file through the legacy/trusted compatibility API."
  @spec run_file(String.t(), keyword()) :: run_result()
  def run_file(path, opts \\ []) do
    with {:ok, source} <- File.read(path),
         graph_hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
         :ok <- verify_expected_graph_hash(opts, graph_hash) do
      # Thread source path and hash for crash recovery + graph version checks
      opts =
        opts
        |> Keyword.put_new(:dot_source_path, Path.expand(path))
        |> Keyword.put_new(:graph_hash, graph_hash)

      run(source, opts)
    end
  end

  @doc "Read a .dot file and securely execute it as an explicit principal."
  @spec run_file_as(String.t(), String.t(), run_credential(), keyword()) :: run_result()
  def run_file_as(path, execution_principal, credential, opts \\ []) do
    with {:ok, source} <- File.read(path),
         graph_hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
         :ok <- verify_expected_graph_hash(opts, graph_hash) do
      opts =
        opts
        |> Keyword.put(:dot_source_path, Path.expand(path))
        |> Keyword.put(:graph_hash, graph_hash)

      run_as(source, execution_principal, credential, opts)
    end
  end

  defp verify_expected_graph_hash(opts, actual_hash) do
    case Keyword.fetch(opts, :graph_hash) do
      :error -> :ok
      {:ok, ^actual_hash} -> :ok
      {:ok, expected_hash} -> {:error, {:graph_hash_mismatch, expected_hash, actual_hash}}
    end
  end

  defp bind_secure_graph_hash(source_or_graph, opts) do
    actual_hash =
      case source_or_graph do
        source when is_binary(source) ->
          :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

        %Graph{} = graph ->
          RunAuthorization.graph_hash(graph)

        _ ->
          nil
      end

    if actual_hash do
      with :ok <- verify_expected_graph_hash(opts, actual_hash) do
        {:ok, Keyword.put(opts, :graph_hash, actual_hash)}
      end
    else
      {:error, :invalid_graph_input}
    end
  end

  defp validate_secure_principal(principal) when is_binary(principal) do
    trimmed = String.trim(principal)

    if trimmed != "" and trimmed == principal and String.valid?(principal) and
         not String.contains?(principal, <<0>>),
       do: :ok,
       else: {:error, :invalid_execution_principal}
  end

  defp validate_secure_principal(_principal), do: {:error, :invalid_execution_principal}

  defp validate_secure_signer(signer) when is_function(signer, 1), do: :ok
  defp validate_secure_signer(_signer), do: {:error, :signer_required}

  defp canonicalize_authority(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, %SigningAuthority{} = authority} -> {:ok, authority}
      {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
    end
  end

  defp validate_authority_principal(%SigningAuthority{principal_id: principal_id}, principal)
       when is_binary(principal) do
    if principal_id == principal,
      do: :ok,
      else: {:error, :principal_mismatch}
  end

  defp validate_authority_principal(_, _), do: {:error, :invalid_signing_authority}

  # Authority path rejects mixed legacy credential controls in opts.
  # Key-presence based: even nil/malformed values count as mixed credentials.
  defp reject_mixed_authority_credentials(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :signing_authority) or
         Keyword.has_key?(opts, :signer) or
         Keyword.has_key?(opts, :authorizer) or
         Keyword.has_key?(opts, :identity_private_key) do
      {:error, :mixed_signing_credentials}
    else
      :ok
    end
  end

  # Legacy signer path rejects any present :signing_authority key (even nil).
  defp reject_signing_authority_in_legacy_opts(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :signing_authority) do
      {:error, :mixed_signing_credentials}
    else
      :ok
    end
  end

  defp validate_principal_opt(opts, principal) do
    supplied = Keyword.get(opts, :execution_principal) || Keyword.get(opts, :agent_id)

    if supplied in [nil, principal],
      do: :ok,
      else: {:error, :execution_principal_mismatch}
  end

  defp secure_authorizer(execution_principal, signer) do
    fn received_principal, _handler_type ->
      if received_principal == execution_principal do
        Arbor.Orchestrator.Authorization.check_orchestrator_access(execution_principal, signer)
      else
        {:error, :execution_principal_mismatch}
      end
    end
  end

  defp reject_early_authorized_overrides(opts) do
    if Keyword.get(opts, :authorization, false) and Keyword.get(opts, :transforms, []) != [] do
      {:error, {:unbound_authorized_override, :transforms}}
    else
      :ok
    end
  end

  @doc """
  Compile a DOT source or Graph into an enriched Graph with typed IR fields.

  The compilation step resolves handler types, validates attribute schemas,
  computes capabilities, data classifications, and parses edge conditions —
  enabling security analysis (taint tracking, capability requirements, loop bounds).
  """
  @spec compile(String.t() | Graph.t(), keyword()) ::
          {:ok, Graph.t()} | {:error, term()}
  def compile(source_or_graph, opts \\ []) do
    # ensure_graph/2 already runs built-ins → IR.Compiler (once) → custom
    # transforms. A second IR.Compiler.compile/1 would re-inject alias defaults
    # and recompute static analysis from post-IR mutations, violating the
    # documented contract that custom transforms cannot influence compiler
    # analyses (and wasting O(nodes+edges) work on cache hits).
    ensure_graph(source_or_graph, opts)
  end

  @doc """
  Compile a reviewed coding plan into deterministic, non-executed pipeline data.

  The template path and compiler module come exclusively from trusted
  orchestrator configuration. This function does not archive, authorize, sign,
  or execute the resulting pipeline.
  """
  @spec compile_coding_plan(Plan.t() | map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def compile_coding_plan(plan_or_attrs) do
    with {:ok, plan} <- normalize_coding_plan(plan_or_attrs),
         :ok <- validate_planner_review_profile(plan),
         {:ok, template_path} <- resolve_coding_plan_template(),
         {:ok, compiler} <- resolve_coding_plan_compiler(),
         {:ok, reply} <- invoke_coding_plan_compiler(compiler, plan, template_path) do
      validate_coding_plan_compiler_reply(reply, plan)
    end
  end

  @doc """
  Verify archived coding-plan provenance against the production compiler and runtime inventory.

  The archived plan, exact DOT bytes, and compile manifest must match a fresh
  trusted compilation. The archived DOT is then parsed and IR-compiled before
  its execution manifest is verified against the live action and handler
  inventory. No archived authority or module selector is accepted.
  """
  @spec verify_coding_provenance(map(), binary(), map()) ::
          {:ok, map()} | {:error, {:invalid_coding_provenance, term()}}
  def verify_coding_provenance(plan_map, dot_source, manifest)
      when is_map(plan_map) and not is_struct(plan_map) and is_binary(dot_source) and
             is_map(manifest) and not is_struct(manifest) do
    with {:ok, plan} <- exact_coding_plan(plan_map),
         {:ok, compilation} <- compile_coding_plan(plan),
         :ok <- require_archived_compilation(compilation, plan_map, dot_source, manifest),
         {:ok, graph} <- parse_coding_provenance_dot(dot_source),
         {:ok, compiled_graph} <- IR.Compiler.compile(graph),
         {:ok, profile} <- Profiles.fetch_executable(plan.validation_profile),
         :ok <- Profiles.validate_requirements(profile, compiled_graph),
         :ok <-
           SemanticPreflight.validate(compiled_graph, profile["semantic_policy"],
             review_profile: plan.review_profile,
             worker_use_pool: plan.worker["use_pool"],
             worker_resume_session_id: plan.worker["resume_session_id"],
             rework_max_cycles: plan.rework["max_cycles"]
           ),
         {:ok, live_catalog} <- ActionCatalog.snapshot(),
         {:ok, _action_bindings} <-
           ExecutionManifest.verify(
             manifest["execution_manifest"],
             manifest["execution_manifest_digest"],
             compiled_graph,
             live_catalog,
             manifest["graph_hash"]
           ),
         {:ok, _handler_bindings} <-
           ExecutionManifest.handler_binding_index(manifest["execution_manifest"]) do
      {:ok,
       %{
         "compiler_version" => manifest["compiler_version"],
         "graph_hash" => manifest["graph_hash"]
       }}
    else
      {:error, {:invalid_coding_provenance, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_coding_provenance, reason}}
      _other -> {:error, {:invalid_coding_provenance, :identity_mismatch}}
    end
  rescue
    _exception -> {:error, {:invalid_coding_provenance, :verification_failed}}
  catch
    _kind, _reason -> {:error, {:invalid_coding_provenance, :verification_failed}}
  end

  def verify_coding_provenance(_plan_map, _dot_source, _manifest),
    do: {:error, {:invalid_coding_provenance, :invalid_input}}

  @doc "Return the exact worktree path production coding leases derive for a branch."
  @spec expected_coding_worktree_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def expected_coding_worktree_path(worktree_base_dir, branch_name) do
    Arbor.Actions.coding_worktree_path(worktree_base_dir, branch_name)
  end

  @doc "Cancel a production coding pipeline by its trusted execution context."
  @spec cancel_coding_task(String.t(), map() | keyword()) :: :ok | {:error, term()}
  def cancel_coding_task(agent_id, context) do
    CodingTaskExecutor.cancel_task(agent_id, context)
  end

  @doc "Run the packaged coding pipeline through the public orchestrator facade."
  @spec run_coding_task(String.t(), map(), map() | keyword()) :: term()
  def run_coding_task(agent_id, task, context) do
    CodingTaskExecutor.run(agent_id, task, context)
  end

  @doc "Return the configured trusted roots for structured coding repositories."
  @spec coding_repo_roots() :: {:ok, [String.t()]} | {:error, term()}
  def coding_repo_roots, do: Config.coding_repo_roots()

  @doc "Return the configured trusted roots for structured coding worktrees."
  @spec coding_worktree_roots() :: {:ok, [String.t()]} | {:error, term()}
  def coding_worktree_roots, do: Config.coding_worktree_roots()

  @doc "Return the configured root for coding pipeline logs and artifacts."
  @spec coding_pipeline_logs_root() :: String.t()
  def coding_pipeline_logs_root, do: Config.coding_pipeline_logs_root()

  @doc """
  Run typed validation passes on a compiled Graph.

  Returns diagnostics from schema validation, capability analysis,
  taint reachability, loop detection, and resource bounds checking.
  These passes complement the structural validation from `validate/2`.
  """
  @spec validate_typed(String.t() | Graph.t(), keyword()) ::
          [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate_typed(%Graph{compiled: true} = compiled, _opts) do
    IR.Validator.validate(compiled)
  end

  def validate_typed(source_or_graph, opts) do
    case compile(source_or_graph, opts) do
      {:ok, compiled} ->
        IR.Validator.validate(compiled)

      {:error, reason} ->
        [
          Diagnostic.error(
            "compile_error",
            "Could not compile to typed IR: #{inspect(reason)}"
          )
        ]
    end
  end

  @doc "Return the spec conformance matrix summary."
  @spec conformance_matrix() :: map()
  def conformance_matrix, do: Conformance.Matrix.summary()

  # ---------------------------------------------------------------------------
  # Pipeline recovery API
  # ---------------------------------------------------------------------------

  @doc """
  List pipelines that were interrupted by a crash and may be resumable.

  Returns entries with `status: :interrupted` that have checkpoint files.
  """
  @spec list_resumable() :: [JobRegistry.Entry.t()]
  def list_resumable do
    JobRegistry.list_interrupted()
    |> Enum.filter(fn entry ->
      entry.logs_root != nil and
        File.exists?(Path.join(entry.logs_root, "checkpoint.json"))
    end)
  end

  @doc """
  Resume an interrupted pipeline by run_id.

  Validates that the checkpoint exists and the DOT source hasn't changed
  since the original run. Returns `{:error, :graph_changed}` if the
  pipeline definition was modified.
  """
  @spec resume(String.t(), keyword()) :: run_result()
  def resume(run_id, opts \\ []) do
    case JobRegistry.get(run_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status not in [:interrupted, :failed] ->
        {:error, {:invalid_status, status}}

      entry ->
        do_resume_entry(entry, opts)
    end
  end

  @doc """
  Mark an interrupted pipeline as abandoned (will not be recovered).
  """
  @spec abandon(String.t()) :: :ok | {:error, term()}
  def abandon(run_id) do
    case JobRegistry.get(run_id) do
      nil -> {:error, :not_found}
      _ -> JobRegistry.mark_abandoned(run_id)
    end
  end

  @doc """
  List resumable pipelines across the cluster.

  Queries both the local JobRegistry (which may have shared Postgres backend)
  and optionally queries peer nodes via RPC for ETS-only deployments.
  """
  @spec list_cluster_resumable() :: [JobRegistry.Entry.t()]
  def list_cluster_resumable do
    local = list_resumable()

    # In shared-Postgres mode, local query already covers all nodes.
    # In ETS-only mode, query peer nodes.
    remote =
      Node.list()
      |> Enum.flat_map(fn node ->
        try do
          :erpc.call(node, __MODULE__, :list_resumable, [], 5_000)
        catch
          _, _ -> []
        end
      end)

    # Deduplicate by run_id
    (local ++ remote)
    |> Enum.uniq_by(fn entry -> entry.run_id || entry.pipeline_id end)
  end

  defp do_resume_entry(entry, opts) do
    checkpoint_path = Path.join(entry.logs_root, "checkpoint.json")

    unless File.exists?(checkpoint_path) do
      {:error, :checkpoint_not_found}
    else
      with :ok <- verify_graph_unchanged(entry) do
        resume_opts =
          [
            resume_from: checkpoint_path,
            run_id: entry.run_id,
            logs_root: entry.logs_root,
            graph_hash: entry.graph_hash,
            dot_source_path: entry.dot_source_path
          ] ++ opts

        case load_graph_for_entry(entry) do
          {:ok, graph} ->
            Engine.run(graph, resume_opts)

          {:error, reason} ->
            {:error, {:cannot_load_graph, reason}}
        end
      end
    end
  end

  defp verify_graph_unchanged(%{graph_hash: nil}), do: :ok
  defp verify_graph_unchanged(%{dot_source_path: nil}), do: :ok

  defp verify_graph_unchanged(%{graph_hash: hash, dot_source_path: path}) do
    case File.read(path) do
      {:ok, source} ->
        current = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
        if current == hash, do: :ok, else: {:error, :graph_changed}

      {:error, _} ->
        # Can't read source file — allow resume from checkpoint
        :ok
    end
  end

  defp load_graph_for_entry(%{dot_source_path: path}) when is_binary(path) do
    case File.read(path) do
      # Resume feeds this graph into Engine.run/2; authorized resume requires
      # an IR-compiled graph (RunAuthorization + compiled_graph_hash/1).
      # compile/1 goes through ensure_graph (DotCache by source hash).
      {:ok, source} -> compile(source)
      {:error, reason} -> {:error, {:dot_file_unavailable, reason}}
    end
  end

  defp load_graph_for_entry(_), do: {:error, :no_dot_source_path}

  defp normalize_coding_plan(%Plan{} = plan), do: {:ok, plan}
  defp normalize_coding_plan(attrs), do: Plan.new(attrs)

  defp exact_coding_plan(plan_map) do
    with {:ok, plan} <- Plan.new(plan_map),
         true <- Plan.to_map(plan) == plan_map do
      {:ok, plan}
    else
      {:error, reason} -> {:error, {:invalid_coding_provenance, {:invalid_plan, reason}}}
      false -> {:error, {:invalid_coding_provenance, :noncanonical_plan}}
    end
  end

  defp require_archived_compilation(compilation, plan_map, dot_source, manifest) do
    if compilation["plan_map"] == plan_map and compilation["dot_source"] == dot_source and
         compilation["manifest"] == manifest do
      :ok
    else
      {:error, {:invalid_coding_provenance, :archived_compilation_mismatch}}
    end
  end

  defp parse_coding_provenance_dot(dot_source) do
    case Parser.parse(dot_source) do
      {:ok, graph} -> {:ok, graph}
      {:ok, _graph, errors} -> {:error, {:dot_parse_failed, errors}}
      {:error, reason} -> {:error, {:dot_parse_failed, reason}}
    end
  end

  defp validate_planner_review_profile(%Plan{review_profile: "none"}),
    do: {:error, {:coding_plan_review_profile_not_allowed, "none"}}

  defp validate_planner_review_profile(%Plan{}), do: :ok

  defp invoke_coding_plan_compiler(compiler, plan, template_path) do
    try do
      {:ok, compiler.compile(plan, template_path: template_path)}
    rescue
      _exception -> {:error, {:coding_plan_compiler_failed, :raise}}
    catch
      :exit, _reason -> {:error, {:coding_plan_compiler_failed, :exit}}
      :throw, _reason -> {:error, {:coding_plan_compiler_failed, :throw}}
    end
  end

  defp validate_coding_plan_compiler_reply({:ok, %Compilation{} = compilation}, plan) do
    case Compilation.validate(compilation, plan) do
      {:ok, validated} ->
        {:ok, Compilation.to_map(validated)}

      {:error, reason} ->
        {:error, {:coding_plan_compiler_invalid_reply, reason}}
    end
  end

  defp validate_coding_plan_compiler_reply({:ok, _payload}, _plan),
    do: {:error, {:coding_plan_compiler_malformed_reply, :invalid_success_payload}}

  defp validate_coding_plan_compiler_reply({:error, reason}, _plan),
    do: {:error, {:coding_plan_compiler_error, compiler_error_tag(reason)}}

  defp validate_coding_plan_compiler_reply(_reply, _plan),
    do: {:error, {:coding_plan_compiler_malformed_reply, :invalid_reply_shape}}

  defp compiler_error_tag(reason) when is_atom(reason), do: reason

  defp compiler_error_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _other -> :returned_error
    end
  end

  defp compiler_error_tag(_reason), do: :returned_error

  defp resolve_coding_plan_template do
    path = Config.coding_pipeline_path()

    if is_binary(path) and String.valid?(path) and String.trim(path) != "" and
         not String.contains?(path, <<0>>) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          {:ok, path}

        {:ok, %File.Stat{type: type}} ->
          {:error, {:coding_plan_template_unavailable, path, {:not_regular_file, type}}}

        {:error, reason} ->
          {:error, {:coding_plan_template_unavailable, path, reason}}
      end
    else
      {:error, {:coding_plan_template_unavailable, :invalid_path}}
    end
  end

  defp resolve_coding_plan_compiler do
    compiler = Config.coding_plan_compiler()

    if is_atom(compiler) and Code.ensure_loaded?(compiler) and
         function_exported?(compiler, :compile, 2) do
      {:ok, compiler}
    else
      {:error, {:coding_plan_compiler_unavailable, compiler}}
    end
  end

  # Already compiled — just apply caller-supplied custom transforms.
  # Built-in transforms (VariableExpansion, ModelStylesheet) are assumed to
  # have already been applied before the caller compiled the graph. Callers
  # that pass a `compiled: true` graph are responsible for the transform-
  # before-compile ordering on their end. New code should pass an uncompiled
  # graph or DOT source and let this module own the order.
  defp ensure_graph(%Graph{compiled: true} = graph, opts),
    do: apply_custom_transforms(graph, opts)

  # Uncompiled Graph struct — built-in transforms FIRST, then IR.Compile,
  # then any caller-supplied custom transforms. The order matters: the
  # compiler's static analyses (capability aggregation, taint profile,
  # data-classification, handler-schema validation) read the post-transform
  # graph so they reflect the values the engine will actually execute. See
  # `apply_pre_compile_transforms/2` for the ordering rationale.
  defp ensure_graph(%Graph{} = graph, opts) do
    with {:ok, transformed} <- apply_pre_compile_transforms(graph, opts),
         {:ok, compiled} <- IR.Compiler.compile(transformed) do
      apply_custom_transforms(compiled, opts)
    end
  end

  defp ensure_graph(source, opts) when is_binary(source) do
    if Keyword.get(opts, :cache, true) do
      ensure_graph_cached(source, opts)
    else
      with {:ok, graph} <- Parser.parse(source),
           {:ok, transformed} <- apply_pre_compile_transforms(graph, opts),
           {:ok, compiled} <- IR.Compiler.compile(transformed) do
        apply_custom_transforms(compiled, opts)
      end
    end
  end

  defp ensure_graph(_, _), do: {:error, :invalid_graph_input}

  defp ensure_graph_cached(source, opts) do
    alias Arbor.Orchestrator.DotCache

    cache_key = DotCache.cache_key(source)

    case DotCache.get(cache_key) do
      {:ok, graph} ->
        # Cache stores the post-built-in-transform + post-compile graph
        # (DotCache @ir_version bumped to 3 when this ordering changed).
        # Custom caller transforms still apply on top per-run.
        apply_custom_transforms(graph, opts)

      miss_or_stale when miss_or_stale in [:miss, :stale] ->
        with {:ok, graph} <- Parser.parse(source),
             {:ok, transformed} <- apply_pre_compile_transforms(graph, opts),
             {:ok, compiled} <- IR.Compiler.compile(transformed) do
          DotCache.put(cache_key, compiled)
          apply_custom_transforms(compiled, opts)
        end
    end
  rescue
    # Cache unavailable (GenServer not started) — fall back to uncached
    ArgumentError ->
      with {:ok, graph} <- Parser.parse(source),
           {:ok, transformed} <- apply_pre_compile_transforms(graph, opts),
           {:ok, compiled} <- IR.Compiler.compile(transformed) do
        apply_custom_transforms(compiled, opts)
      end
  end

  # Built-in transforms applied BEFORE IR.Compile so the compiler's static
  # analyses see post-transform values. Both transforms are deterministic
  # from the DOT source (VariableExpansion reads `graph.attrs`,
  # ModelStylesheet reads `graph.attrs["model_stylesheet"]`) so cache
  # invalidation by source hash remains sound.
  defp apply_pre_compile_transforms(graph, _opts) do
    run_transforms(graph, [VariableExpansion, ModelStylesheet])
  end

  # Caller-supplied transforms applied AFTER IR.Compile. These are the
  # extensibility hook for downstream callers that want to mutate a
  # compiled graph — they cannot influence the compiler's analyses by
  # design (would invalidate the cache otherwise).
  defp apply_custom_transforms(graph, opts) do
    case Keyword.get(opts, :transforms, []) do
      [] -> {:ok, graph}
      custom -> run_transforms(graph, custom)
    end
  end

  defp run_transforms(graph, transforms) do
    Enum.reduce_while(transforms, {:ok, graph}, fn transform, {:ok, acc} ->
      case apply_transform(transform, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_transform(module, graph) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        cond do
          function_exported?(module, :transform, 1) ->
            normalize_transform_result(module.transform(graph), module)

          function_exported?(module, :apply, 1) ->
            normalize_transform_result(module.apply(graph), module)

          true ->
            {:error, {:invalid_transform, module}}
        end

      {:error, _} ->
        {:error, {:invalid_transform, module}}
    end
  end

  defp apply_transform(fun, graph) when is_function(fun, 1) do
    normalize_transform_result(fun.(graph), fun)
  end

  defp apply_transform(other, _graph), do: {:error, {:invalid_transform, other}}

  defp normalize_transform_result({:ok, %Graph{} = graph}, _transform), do: {:ok, graph}
  defp normalize_transform_result(%Graph{} = graph, _transform), do: {:ok, graph}
  defp normalize_transform_result({:error, reason}, _transform), do: {:error, reason}

  defp normalize_transform_result(other, transform),
    do: {:error, {:transform_failed, transform, other}}
end
