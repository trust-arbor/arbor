defmodule Arbor.Orchestrator.Handlers.PipelineRunHandler do
  @moduledoc """
  Handler that executes a child pipeline (DOT graph) synchronously.

  Node attributes:
    - `source_key` - context key containing DOT string (default: "last_response")
    - `source_file` - alternative: path to a .dot file to run
    - `workdir` - working directory for the child pipeline (inherits parent if unset)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}

  @impl true
  def execute(node, context, _graph, opts) do
    source = get_source(node, context, opts)

    unless source do
      raise "no DOT source found — set 'source_key' or 'source_file' attribute"
    end

    child_opts = build_child_opts(node, context, opts)

    case Arbor.Orchestrator.run(source, child_opts) do
      {:ok, result} ->
        child_status = result.final_outcome && result.final_outcome.status
        completed = length(result.completed_nodes)

        context_updates =
          %{
            "pipeline.ran.#{node.id}" => true,
            "pipeline.child_status.#{node.id}" => to_string(child_status || :unknown),
            "pipeline.child_nodes_completed.#{node.id}" => completed
          }
          |> merge_child_context(node.id, result.context)

        if child_status == :success do
          %Outcome{
            status: :success,
            notes: "Child pipeline completed: #{completed} nodes",
            context_updates: context_updates
          }
        else
          %Outcome{
            status: :fail,
            failure_reason:
              "Child pipeline ended with status #{child_status}: #{result.final_outcome && result.final_outcome.failure_reason}",
            context_updates: context_updates
          }
        end

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "Child pipeline error: #{inspect(reason)}",
          context_updates: %{
            "pipeline.ran.#{node.id}" => false
          }
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "pipeline.run error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  defp get_source(node, context, opts) do
    if Map.get(node.attrs, "source_file") do
      path = Map.get(node.attrs, "source_file")
      workdir = fixed_workdir(context, opts)

      with {:ok, content} <- read_source_file(path, workdir, opts) do
        content
      else
        _ -> nil
      end
    else
      key = Map.get(node.attrs, "source_key", "last_response")
      Context.get(context, key)
    end
  end

  defp build_child_opts(_node, context, opts) do
    workdir = fixed_workdir(context, opts)

    # P0-3: thread the authorization context into the child graph run.
    # The pre-fix Keyword.take dropped :authorization, :authorizer,
    # :signer, and :auth_context — child pipelines started with no
    # parent auth context at all.
    forwarded_keys = [
      :logs_root,
      :on_event,
      :authorization,
      :authorizer,
      :signer,
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

    child_opts = Keyword.take(opts, forwarded_keys)

    child_opts =
      if workdir, do: Keyword.put(child_opts, :workdir, workdir), else: child_opts

    # H16: decrement the recursion budget so nested pipeline.run calls
    # eventually hit the engine's max_depth gate.
    parent_depth = Keyword.get(opts, :max_depth, 3)
    Keyword.put(child_opts, :max_depth, parent_depth - 1)
  end

  defp fixed_workdir(context, opts) do
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

  # Promote selected child context values into parent context under a namespace
  defp merge_child_context(updates, node_id, child_context) when is_map(child_context) do
    child_context
    |> Enum.filter(fn {key, _v} ->
      is_binary(key) and not String.starts_with?(key, "graph.")
    end)
    |> Enum.reduce(updates, fn {key, value}, acc ->
      # Only promote JSON-serializable scalar values
      if is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
        Map.put(acc, "pipeline.child.#{node_id}.#{key}", value)
      else
        acc
      end
    end)
  end

  defp merge_child_context(updates, _node_id, _), do: updates
end
