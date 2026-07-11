defmodule Arbor.Orchestrator.Handlers.SubgraphHandler do
  @moduledoc """
  Handler for hierarchical graph composition.

  Executes a child graph from within a parent graph with explicit
  context passing and result mapping. No implicit inheritance —
  child graphs start with empty context unless explicitly given keys.

  Dispatches by `type` attribute:

    * `graph.invoke`  — execute a named or file-referenced child graph
    * `graph.compose` — execute a DOT string from context

  ## Node attributes

    * `graph_name`       — resolve from GraphRegistry
    * `graph_file`       — path to .dot file
    * `graph_source_key` — context key containing DOT string (for invoke)
    * `source_key`       — context key containing DOT string (for compose, default: `"last_response"`)
    * `pass_context`     — comma-separated list of context keys to pass to child
    * `pass_all_context` — `"true"` to pass entire parent context (not recommended)
    * `result_mapping`   — comma-separated `child_key:parent_key` pairs
    * `result_prefix`    — prefix for all child context keys (default: `"subgraph.<node_id>."`)
    * `ignore_child_failure` — `"true"` to continue even if child fails
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.GraphRegistry

  @impl true
  def execute(node, context, _graph, opts) do
    type = Map.get(node.attrs, "type", "graph.invoke")
    handle_type(type, node, context, opts)
  rescue
    e -> fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Dispatch ---

  defp handle_type("graph.invoke", node, context, opts) do
    with {:ok, dot_source} <- resolve_graph_source(node, context, opts),
         {:ok, child_context_values} <- build_child_context(node, context),
         {:ok, child_opts} <- build_child_opts(node, opts) do
      run_child(dot_source, child_context_values, child_opts, node, context)
    else
      {:error, reason} -> fail("graph.invoke: #{inspect(reason)}")
    end
  end

  defp handle_type("graph.compose", node, context, opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    dot_source = Context.get(context, source_key)

    if dot_source do
      with {:ok, child_context_values} <- build_child_context(node, context),
           {:ok, child_opts} <- build_child_opts(node, opts) do
        run_child(dot_source, child_context_values, child_opts, node, context)
      else
        {:error, reason} -> fail("graph.compose: #{inspect(reason)}")
      end
    else
      fail("graph.compose: no DOT source at context key '#{source_key}'")
    end
  end

  defp handle_type(type, _node, _context, _opts) do
    fail("unknown graph node type: #{type}")
  end

  # --- Child execution ---

  defp run_child(dot_source, child_context_values, child_opts, node, context) do
    # Taint inheritance across the subgraph boundary (taint-rebuild Phase 3):
    # carry the provenance of the passed-in keys INTO the child so the child's
    # internal enforcement sees it, and carry the child's final provenance back
    # OUT so the parent's downstream nodes are gated on child-produced taint.
    child_taint = build_child_taint(node, context)

    child_opts =
      child_opts
      |> Keyword.put(:initial_values, child_context_values)
      |> Keyword.put(:initial_taint, child_taint)

    case Arbor.Orchestrator.run(dot_source, child_opts) do
      {:ok, result} ->
        child_status = result.final_outcome && result.final_outcome.status
        ignore_failure = Map.get(node.attrs, "ignore_child_failure") == "true"

        context_updates =
          map_child_results(node, result.context)
          |> Map.put("subgraph.#{node.id}.status", to_string(child_status || :unknown))
          |> Map.put(
            "subgraph.#{node.id}.nodes_completed",
            length(result.completed_nodes)
          )

        # Collapse the child's per-key taint into one boundary %Taint{} applied
        # to all of this node's outputs (conservative — over-taints rather than
        # leaking provenance). Includes the inherited input taint as a floor.
        out_taint =
          Context.combine(Map.values(child_taint) ++ Map.values(result.taint || %{}))

        if child_status == :success or ignore_failure do
          %Outcome{
            status: :success,
            notes: "Child graph completed: #{length(result.completed_nodes)} nodes",
            context_updates: context_updates,
            output_taint: out_taint
          }
        else
          failure_reason =
            (result.final_outcome && result.final_outcome.failure_reason) || "unknown"

          %Outcome{
            status: :fail,
            failure_reason: "Child graph failed: #{failure_reason}",
            context_updates: context_updates
          }
        end

      {:error, reason} ->
        ignore_failure = Map.get(node.attrs, "ignore_child_failure") == "true"

        if ignore_failure do
          %Outcome{
            status: :success,
            notes: "Child graph error (ignored): #{inspect(reason)}",
            context_updates: %{
              "subgraph.#{node.id}.status" => "error",
              "subgraph.#{node.id}.error" => inspect(reason)
            }
          }
        else
          fail("child graph error: #{inspect(reason)}")
        end
    end
  end

  # --- Graph resolution ---

  defp resolve_graph_source(node, context, opts) do
    cond do
      name = Map.get(node.attrs, "graph_name") ->
        GraphRegistry.resolve(name)

      file = Map.get(node.attrs, "graph_file") ->
        workdir = fixed_workdir(opts, context)

        with {:ok, content} <- read_source_file(file, workdir, opts) do
          {:ok, content}
        else
          {:error, reason} -> {:error, {:file_read, reason, file}}
        end

      key = Map.get(node.attrs, "graph_source_key") ->
        case Context.get(context, key) do
          nil -> {:error, "no DOT source at context key '#{key}'"}
          dot -> {:ok, dot}
        end

      true ->
        {:error, "no graph source: set graph_name, graph_file, or graph_source_key"}
    end
  end

  # --- Context isolation ---

  defp build_child_context(node, context) do
    cond do
      Map.get(node.attrs, "pass_all_context") == "true" ->
        {:ok, context.values}

      keys_str = Map.get(node.attrs, "pass_context") ->
        keys = String.split(keys_str, ",") |> Enum.map(&String.trim/1)

        values =
          Enum.reduce(keys, %{}, fn key, acc ->
            case Context.get(context, key) do
              nil -> acc
              val -> Map.put(acc, key, val)
            end
          end)

        {:ok, values}

      true ->
        {:ok, %{}}
    end
  end

  # The provenance taint of the keys passed into the child — mirrors the key
  # selection in build_child_context/2 so the child inherits the right labels.
  defp build_child_taint(node, context) do
    full = Context.taint_map(context)

    cond do
      Map.get(node.attrs, "pass_all_context") == "true" ->
        full

      keys_str = Map.get(node.attrs, "pass_context") ->
        keys_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reduce(%{}, fn key, acc ->
          case Map.get(full, key) do
            nil -> acc
            level -> Map.put(acc, key, level)
          end
        end)

      true ->
        %{}
    end
  end

  # --- Result mapping ---

  defp map_child_results(node, child_context) when is_map(child_context) do
    case Map.get(node.attrs, "result_mapping") do
      mapping when not is_nil(mapping) ->
        apply_explicit_mapping(mapping, child_context)

      _ ->
        prefix = Map.get(node.attrs, "result_prefix", "subgraph.#{node.id}.")
        apply_prefix_mapping(prefix, child_context)
    end
  end

  defp map_child_results(_node, _), do: %{}

  defp apply_explicit_mapping(mapping_str, child_context) do
    mapping_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [child_key, parent_key] ->
          case Map.get(child_context, String.trim(child_key)) do
            nil -> acc
            val -> Map.put(acc, String.trim(parent_key), val)
          end

        _ ->
          acc
      end
    end)
  end

  defp apply_prefix_mapping(prefix, child_context) do
    child_context
    |> Enum.filter(fn {key, _} ->
      is_binary(key) and not String.starts_with?(key, "graph.")
    end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
        Map.put(acc, "#{prefix}#{key}", value)
      else
        acc
      end
    end)
  end

  # --- Child opts ---

  defp build_child_opts(node, parent_opts) do
    # P0-3: thread the authorization context through to child graph execution.
    # Pre-fix, build_child_opts took only :on_event (and optionally :logs_root),
    # which meant nested pipelines started with NO authorizer, NO signer, and
    # NO auth_context — the parent's grants and identity were silently
    # discarded. Auth keys are forwarded explicitly here; per-node checks at
    # the child level then see the same context the parent saw.
    # Include :signing_authority so a parent authority run never silently
    # becomes authority-absent (legacy authorizer/signer/config path) in the
    # child. Authority is process-local opts only — never Engine context.
    forwarded_keys = [
      :on_event,
      :authorization,
      :authorizer,
      :signer,
      :signing_authority,
      :auth_context,
      :run_authorization,
      :execution_principal,
      :agent_id,
      :caller_id,
      :author_id,
      :task_id,
      :session_id,
      :workdir,
      :identity_private_key,
      :execution_manifest,
      :execution_manifest_digest,
      :pinned_action_bindings,
      :pinned_handler_bindings,
      :pinned_node_bindings,
      :resumable
    ]

    child_opts = Keyword.take(parent_opts, forwarded_keys)

    logs_root = Keyword.get(parent_opts, :logs_root)

    child_opts =
      if logs_root do
        child_logs = Path.join(logs_root, "subgraph_#{node.id}")
        File.mkdir_p(child_logs)
        Keyword.put(child_opts, :logs_root, child_logs)
      else
        child_opts
      end

    # H16: decrement the recursion budget before invoking the child graph.
    # The engine refuses to run when max_depth < 0, so a runaway nest
    # terminates with {:error, :max_depth_exceeded}.
    parent_depth = Keyword.get(parent_opts, :max_depth, 3)
    child_opts = Keyword.put(child_opts, :max_depth, parent_depth - 1)

    {:ok, child_opts}
  end

  defp fixed_workdir(opts, context) do
    case Keyword.get(opts, :run_authorization) do
      %RunAuthorization{workdir: workdir} -> workdir
      _ -> Path.expand(Context.get(context, "workdir") || Keyword.get(opts, :workdir, "."))
    end
  end

  defp resolve_source_file(path, workdir) do
    expanded_workdir = Path.expand(workdir)

    with {:ok, lexical_path} <- SafePath.resolve_within(path, expanded_workdir),
         {:ok, canonical_root} <- SafePath.resolve_real(expanded_workdir),
         {:ok, real_path} <- SafePath.resolve_real(lexical_path),
         {:ok, ^real_path} <- SafePath.resolve_within(real_path, canonical_root) do
      {:ok,
       %{
         canonical_root: canonical_root,
         expanded_workdir: expanded_workdir,
         lexical_path: lexical_path,
         real_path: real_path
       }}
    else
      {:ok, _outside_path} -> {:error, :path_traversal}
      {:error, _reason} = error -> error
    end
  end

  defp read_source_file(path, workdir, opts) do
    with {:ok, resolved} <- resolve_source_file(path, workdir),
         {:ok, authorized_identity} <- regular_file_identity(resolved.real_path),
         {:ok, io_device} <- File.open(resolved.real_path, [:read, :binary, :raw]) do
      try do
        read_open_source_file(io_device, resolved, authorized_identity, opts)
      after
        File.close(io_device)
      end
    end
  end

  defp read_open_source_file(io_device, resolved, authorized_identity, opts) do
    with {:ok, opened_identity} <- open_file_identity(io_device),
         true <- opened_identity == authorized_identity,
         :ok <- run_source_file_hook(opts, :source_file_after_open_hook, resolved.real_path),
         {:ok, content} <- read_open_file(io_device),
         {:ok, post_read_identity} <- open_file_identity(io_device),
         true <- post_read_identity == opened_identity,
         true <- byte_size(content) == opened_identity.size,
         :ok <- run_source_file_hook(opts, :source_file_post_read_hook, resolved.real_path),
         :ok <- verify_source_file(resolved, opened_identity) do
      {:ok, content}
    else
      false -> {:error, :source_file_changed_during_read}
      {:error, _reason} = error -> error
      _other -> {:error, :source_file_changed_during_read}
    end
  end

  defp verify_source_file(resolved, expected_identity) do
    with {:ok, canonical_root} <- SafePath.resolve_real(resolved.expanded_workdir),
         true <- canonical_root == resolved.canonical_root,
         {:ok, real_path} <- SafePath.resolve_real(resolved.lexical_path),
         true <- real_path == resolved.real_path,
         {:ok, ^real_path} <- SafePath.resolve_within(real_path, canonical_root),
         {:ok, identity} <- regular_file_identity(real_path),
         true <- identity == expected_identity do
      :ok
    else
      _other -> {:error, :source_file_changed_during_read}
    end
  end

  defp regular_file_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok,
         %{
           inode: stat.inode,
           major_device: stat.major_device,
           minor_device: stat.minor_device,
           size: stat.size,
           mtime: stat.mtime,
           ctime: stat.ctime
         }}

      {:ok, %File.Stat{}} ->
        {:error, :source_not_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_file_identity(io_device) do
    case :file.read_file_info(io_device, time: :posix) do
      {:ok, file_info} ->
        case File.Stat.from_record(file_info) do
          %File.Stat{type: :regular} = stat ->
            {:ok,
             %{
               inode: stat.inode,
               major_device: stat.major_device,
               minor_device: stat.minor_device,
               size: stat.size,
               mtime: stat.mtime,
               ctime: stat.ctime
             }}

          %File.Stat{} ->
            {:error, :source_not_regular_file}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_open_file(io_device) do
    case IO.binread(io_device, :eof) do
      content when is_binary(content) -> {:ok, content}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # Hooks are function-valued Engine opts used only by deterministic tests;
  # graph attributes and graph context cannot supply executable hook values.
  defp run_source_file_hook(opts, hook_name, real_path) do
    case Keyword.get(opts, hook_name) do
      nil ->
        :ok

      hook when is_function(hook, 1) ->
        hook.(real_path)
        :ok

      _invalid ->
        {:error, :invalid_source_file_read_hook}
    end
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end
end
