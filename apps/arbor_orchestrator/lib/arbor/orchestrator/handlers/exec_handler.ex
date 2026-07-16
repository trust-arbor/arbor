defmodule Arbor.Orchestrator.Handlers.ExecHandler do
  @moduledoc """
  Core handler for side-effecting execution — tools, shell commands, actions.

  Canonical type: `exec`
  Aliases: `tool`, `shell`

  Dispatches by `target` attribute:
    - `"tool"` (default) — delegates to ToolHandler
    - `"shell"` — delegates to ShellHandler
    - `"action"` — executes an Arbor action via ActionsExecutor
    - `"function"` — calls a function reference from opts

  ## Node Attributes

    - `target` — execution target: "tool" (default), "shell", "action", "function"
    - `action` — action name (required when target="action"), e.g. "eval_pipeline.load_dataset"
    - `arg.*` / `param.*` — action parameters extracted from attrs
    - `context_keys` — comma-separated context keys whose values are merged as
      action params. Namespaced keys (e.g. `exec.load_dataset.dataset`) are
      normalized to the last segment (`dataset`) so they match flat Jido schema
      keys. Already-flat keys are preserved. Duplicate normalized parameter
      names fail closed before execution. Per-parameter taint is keyed by the
      same flat action parameter names while still reading provenance from the
      exact source context keys.
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}

  alias Arbor.Orchestrator.Handlers.{
    ShellHandler,
    ToolHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    if Keyword.get(opts, :authorization, false) and
         not match?(%RunAuthorization{}, Keyword.get(opts, :run_authorization)) do
      %Outcome{status: :fail, failure_reason: "exec authorization missing immutable principal"}
    else
      target = Map.get(node.attrs, "target", "tool")

      with {:ok, [{slot, execution_module}]} <- execution_delegates(node, opts),
           :ok <-
             RunAuthorization.verify_execution_module(
               Keyword.get(opts, :run_authorization),
               node,
               slot,
               execution_module
             ) do
        dispatch(target, execution_module, node, context, graph, opts)
      else
        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason:
              "Exec delegate binding rejected for node #{node.id}: #{inspect(reason)}"
          }

        _other ->
          %Outcome{status: :fail, failure_reason: "Invalid exec delegate for node #{node.id}"}
      end
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  @doc false
  def execution_delegates(node), do: execution_delegates(node, [])

  @doc false
  def execution_delegates(node, opts) do
    target = Map.get(node.attrs, "target", "tool")

    selected =
      case target do
        "tool" -> ToolHandler
        "shell" -> ShellHandler
        "action" -> Keyword.get(opts, :actions_executor, Arbor.Orchestrator.ActionsExecutor)
        "function" -> nil
        _unknown -> ToolHandler
      end

    if is_atom(selected) or is_nil(selected) do
      {:ok, [{"exec:#{target}", selected}]}
    else
      {:error, {:invalid_exec_delegate, target}}
    end
  end

  defp dispatch("tool", module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp dispatch("shell", module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp dispatch("action", executor, node, context, _graph, opts),
    do: execute_action(node, context, opts, executor)

  defp dispatch("function", nil, node, context, _graph, opts),
    do: execute_function(node, context, opts)

  defp dispatch(_unknown, module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp execute_action(node, context, opts, executor) do
    action_name = Map.get(node.attrs, "action")

    if action_name in [nil, ""] do
      raise "exec with target=action requires non-empty 'action' attribute"
    end

    if Code.ensure_loaded?(executor) do
      authority = Keyword.get(opts, :run_authorization)

      {agent_id, caller_id, author_id, task_id, session_id, workdir} =
        case authority do
          %RunAuthorization{} = auth ->
            {
              auth.execution_principal,
              auth.caller_id,
              auth.author_id,
              auth.task_id,
              auth.session_id,
              auth.workdir
            }

          _ ->
            {
              Map.get(node.attrs, "agent_id") ||
                Context.get(context, "session.agent_id", "system"),
              Keyword.get(opts, :caller_id),
              Keyword.get(opts, :author_id),
              Context.get(context, "session.task_id") || Keyword.get(opts, :task_id),
              Keyword.get(opts, :session_id),
              Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")
            }
        end

      # Preserve the aggregate taint for operation-level authorization, egress,
      # and telemetry while also carrying each runtime parameter's exact label
      # to the action enforcement boundary. Static attr args are author-written;
      # only context_keys values can be runtime-tainted.
      context_keys = consumed_context_keys(node.attrs)
      input_taint = Context.worst_taint(context, context_keys)
      output_prefix = Map.get(node.attrs, "output_prefix")

      case build_action_args(node.id, node.attrs, context) do
        {:ok, action_args, param_taint} ->
          executor_opts =
            [
              agent_id: agent_id,
              caller_id: caller_id,
              author_id: author_id,
              task_id: task_id,
              session_id: session_id,
              taint: input_taint
            ]
            |> maybe_put_action_signer(opts)
            |> maybe_put_param_taint(param_taint, context_keys)
            |> maybe_put_execution_binding(authority)
            |> maybe_put_nested_engine_controls(opts, authority)
            |> maybe_put_approval_timeout(opts)
            |> maybe_put_execution_id(opts)
            |> maybe_put_transcript_sink(opts)

          try do
            case executor.execute(action_name, action_args, workdir, executor_opts) do
              {:ok, result} ->
                %Outcome{
                  status: :success,
                  notes: "Action #{action_name} executed",
                  context_updates:
                    flatten_context_updates(node.id, result)
                    |> maybe_add_prefixed_keys(node.id, result, output_prefix),
                  # Provenance (Phase 1): if this action is an ingress (e.g. web
                  # fetch -> :untrusted, or a foreign-path file read), label its
                  # output keys so downstream nodes that consume them are gated at
                  # control params. Params let path-based actions decide provenance.
                  output_taint: action_output_taint(executor, action_name, action_args)
                }

              {:error, reason} ->
                %Outcome{
                  status: :fail,
                  failure_reason: "Action #{action_name} failed: #{reason}"
                }

              other ->
                # No control-protocol projection: unexpected tuples (including legacy
                # {:control, _}) fail closed so denial can never become success via
                # an author-controlled handler attribute.
                %Outcome{
                  status: :fail,
                  failure_reason:
                    "Action #{action_name} returned unsupported result: #{inspect(other)}"
                }
            end
          catch
            :exit, reason ->
              %Outcome{
                status: :fail,
                failure_reason: "Action #{action_name} process error: #{inspect(reason)}"
              }
          end

        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason:
              "Action #{action_name} context_keys invalid: #{format_context_keys_error(reason)}"
          }
      end
    else
      %Outcome{
        status: :fail,
        failure_reason: "Arbor.Orchestrator.ActionsExecutor not available"
      }
    end
  end

  defp execute_function(node, _context, opts) do
    case Keyword.get(opts, :function_handler) do
      fun when is_function(fun, 1) ->
        args = parse_attr_args(node.id, node.attrs)

        case fun.(args) do
          {:ok, result} ->
            %Outcome{
              status: :success,
              notes: "Function executed",
              context_updates: %{
                "exec.#{node.id}.result" => inspect(result),
                "last_response" => inspect(result)
              }
            }

          {:error, reason} ->
            %Outcome{
              status: :fail,
              failure_reason: "Function failed: #{inspect(reason)}"
            }

          other ->
            %Outcome{
              status: :success,
              notes: "Function executed",
              context_updates: %{
                "exec.#{node.id}.result" => inspect(other),
                "last_response" => inspect(other)
              }
            }
        end

      nil ->
        %Outcome{
          status: :fail,
          failure_reason: "exec with target=function requires :function_handler in opts"
        }
    end
  end

  # Build action args from both attr-prefixed values AND context keys.
  #
  # Context keys are looked up by their full source name (so namespaced
  # pipeline outputs like `exec.load_dataset.dataset` resolve), then inserted
  # under the flat last-segment action parameter name (`dataset`) so
  # ActionsExecutor schema atomization can match Jido keys. Per-parameter
  # taint follows the same flat keys while provenance still comes from each
  # exact source key. Duplicate normalized parameter names fail closed.
  defp build_action_args(node_id, attrs, context) do
    attr_args = parse_attr_args(node_id, attrs)
    source_keys = consumed_context_keys(attrs)

    case resolve_context_params(node_id, source_keys, context, attr_args) do
      {:ok, context_args, param_taint} ->
        {:ok, Map.merge(attr_args, context_args), param_taint}

      {:error, _reason} = error ->
        error
    end
  end

  # The context keys whose values are interpolated into this action's params.
  # These are the only runtime-tainted inputs (static arg.*/param.* attrs are
  # author-written and trusted).
  defp consumed_context_keys(attrs) do
    case Map.get(attrs, "context_keys") do
      nil ->
        []

      keys_csv ->
        keys_csv
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp resolve_context_params(node_id, source_keys, context, attr_args) do
    Enum.reduce_while(source_keys, {:ok, %{}, %{}, MapSet.new()}, fn source_key,
                                                                     {:ok, args, taints, seen} ->
      param_name = action_param_name(source_key)

      if MapSet.member?(seen, param_name) do
        {:halt, {:error, {:duplicate_context_param, param_name, source_key}}}
      else
        seen = MapSet.put(seen, param_name)

        case Context.get(context, source_key) do
          nil ->
            # Silent param loss is the bug: action runs with a
            # partial param set and the operator gets no signal.
            # Skip the warning when a static arg.*/param.* already
            # supplies this flat parameter (optional CLI overrides).
            unless Map.has_key?(attr_args, param_name) do
              Logger.warning(
                "[ExecHandler] #{node_id}: context_keys references " <>
                  "\"#{source_key}\" but no such key in context; param " <>
                  "\"#{param_name}\" will be missing from action call"
              )
            end

            {:cont, {:ok, args, taints, seen}}

          value ->
            taint = Context.taint_label(context, source_key)

            {:cont,
             {:ok, Map.put(args, param_name, value), Map.put(taints, param_name, taint), seen}}
        end
      end
    end)
    |> case do
      {:ok, args, taints, _seen} -> {:ok, args, taints}
      {:error, _reason} = error -> error
    end
  end

  # Map a consumed context key to the flat action parameter name.
  # Already-flat keys pass through; namespaced pipeline keys keep the leaf.
  # Uses only string splits — never converts untrusted strings to atoms.
  defp action_param_name(context_key) when is_binary(context_key) do
    case String.split(context_key, ".") do
      [single] -> single
      parts -> List.last(parts)
    end
  end

  defp maybe_put_param_taint(opts, _param_taint, []), do: opts

  defp maybe_put_param_taint(opts, param_taint, _context_keys) do
    Keyword.put(opts, :param_taint, param_taint)
  end

  defp format_context_keys_error({:duplicate_context_param, param_name, source_key}) do
    "duplicate action parameter #{inspect(param_name)} from context key #{inspect(source_key)}; " <>
      "each context_keys entry must normalize to a distinct flat parameter name"
  end

  defp format_context_keys_error(reason), do: inspect(reason)

  defp maybe_put_execution_binding(opts, %RunAuthorization{} = authority) do
    opts
    |> maybe_put_executor_opt(:execution_manifest, authority.execution_manifest)
    |> maybe_put_executor_opt(
      :execution_manifest_digest,
      authority.execution_manifest_digest
    )
    |> maybe_put_executor_opt(:pinned_action_bindings, authority.pinned_action_bindings)
  end

  defp maybe_put_execution_binding(opts, _authority), do: opts

  # Signing credentials are mutually exclusive by key presence. Authority runs
  # forward only :signing_authority below; inserting even `signer: nil` here
  # makes ActionsExecutor correctly reject the invocation as mixed credentials.
  defp maybe_put_action_signer(executor_opts, engine_opts) do
    case Keyword.fetch(engine_opts, :signing_authority) do
      {:ok, _authority} -> executor_opts
      :error -> maybe_put_executor_opt(executor_opts, :signer, Keyword.get(engine_opts, :signer))
    end
  end

  # Council actions can launch a child Engine run. Forward only the live,
  # non-secret controls that bind that child to this authorized parent run.
  # When a parent run carries :signing_authority, forward it so nested council
  # Engine execution stays in fixed-facade authority mode (never silent legacy).
  # Do not put authority into Engine context/checkpoints — nested_engine_opts
  # is process-local action context only.
  defp maybe_put_nested_engine_controls(opts, engine_opts, %RunAuthorization{} = authority) do
    opts
    |> Keyword.put(:run_authorization, authority)
    |> maybe_put_nested_signing_credentials(engine_opts)
    |> Keyword.put(:max_depth, Keyword.get(engine_opts, :max_depth, 3))
  end

  defp maybe_put_nested_engine_controls(opts, _engine_opts, _authority), do: opts

  # Presence-based: when :signing_authority is present on the parent Engine
  # opts, forward only that credential (not legacy authorizer/signer) so nested
  # exclusivity checks stay consistent with the parent authority run.
  defp maybe_put_nested_signing_credentials(opts, engine_opts) do
    case Keyword.fetch(engine_opts, :signing_authority) do
      {:ok, signing_authority} ->
        Keyword.put(opts, :signing_authority, signing_authority)

      :error ->
        maybe_put_executor_opt(opts, :authorizer, Keyword.get(engine_opts, :authorizer))
    end
  end

  # Approval timeout is Engine control data (never a node attr / context_keys
  # value). Forward it generically when present — coding-specific wall-clock
  # bounds live in CodingTaskExecutor, not this generic handler.
  defp maybe_put_approval_timeout(executor_opts, engine_opts) do
    case Keyword.get(engine_opts, :approval_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        Keyword.put(executor_opts, :approval_timeout_ms, timeout_ms)

      _ ->
        executor_opts
    end
  end

  # Owner-issued effect execution ID is process-local Engine handler control
  # data only. Forward the exact value when present; never read it from DOT
  # attrs, action params, Engine Context, or user data, and never inject it
  # into action params / Outcome updates.
  defp maybe_put_execution_id(executor_opts, engine_opts) do
    case Keyword.fetch(engine_opts, :execution_id) do
      {:ok, execution_id} when not is_nil(execution_id) ->
        Keyword.put(executor_opts, :execution_id, execution_id)

      _ ->
        executor_opts
    end
  end

  # Reload-stable process-local capture data comes only from trusted Engine opts.
  # It never enters node attrs, action params, Context, or checkpoints.
  defp maybe_put_transcript_sink(executor_opts, engine_opts) do
    case Keyword.fetch(engine_opts, :transcript_sink) do
      :error ->
        executor_opts

      {:ok, nil} ->
        executor_opts

      {:ok, {module, function, fixed_args} = sink}
      when is_atom(module) and is_atom(function) and is_list(fixed_args) ->
        Keyword.put(executor_opts, :transcript_sink, sink)

      {:ok, _malformed} ->
        Keyword.put(
          executor_opts,
          :transcript_capture_error,
          :invalid_trusted_transcript_capture
        )
    end
  end

  defp maybe_put_executor_opt(opts, _key, nil), do: opts
  defp maybe_put_executor_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Provenance taint this action assigns to its own output, via the executor's
  # output_taint/1 resolver (nil for non-ingress actions or standalone mode).
  defp action_output_taint(executor, action_name, params) do
    cond do
      function_exported?(executor, :output_taint, 2) -> executor.output_taint(action_name, params)
      function_exported?(executor, :output_taint, 1) -> executor.output_taint(action_name)
      true -> nil
    end
  end

  defp parse_attr_args(node_id, attrs) do
    attrs
    |> Enum.filter(fn {k, _v} ->
      String.starts_with?(k, "arg.") or String.starts_with?(k, "param.")
    end)
    |> Enum.map(fn {k, v} ->
      key = k |> String.replace(~r/^(arg|param)\./, "")
      # Jido action schemas use flat atom keys. A nested attr like
      # `arg.foo.bar` produces a string key "foo.bar" that won't
      # match any schema atom and silently gets ignored by the
      # action — dead weight with no signal. Warn so the typo
      # (or hallucinated nested form) surfaces.
      if String.contains?(key, ".") do
        Logger.warning(
          "[ExecHandler] #{node_id}: attr \"#{k}\" produced nested param " <>
            "key \"#{key}\" — Jido schemas use flat atom keys, so this " <>
            "param will be silently dropped by the action. Did you mean " <>
            "to use \"_\" instead of \".\" after the prefix?"
        )
      end

      {key, v}
    end)
    |> Map.new()
  end

  # Flatten action result into context updates.
  # If result is a JSON map, spread its keys as "exec.{node_id}.{key}".
  defp flatten_context_updates(node_id, result) when is_binary(result) do
    base = %{
      "exec.#{node_id}.result" => result,
      "last_response" => result
    }

    case Jason.decode(result) do
      {:ok, map} when is_map(map) ->
        spread =
          Enum.reduce(map, %{}, fn {k, v}, acc ->
            Map.put(acc, "exec.#{node_id}.#{k}", v)
          end)

        Map.merge(base, spread)

      _ ->
        base
    end
  end

  defp flatten_context_updates(node_id, result) do
    %{
      "exec.#{node_id}.result" => inspect(result),
      "last_response" => inspect(result)
    }
  end

  # When output_prefix is set, duplicate each spread key under the prefix namespace.
  # Example: output_prefix="session" + result key "cognitive_mode"
  # → writes both "exec.node_id.cognitive_mode" AND "session.cognitive_mode"
  defp maybe_add_prefixed_keys(updates, _node_id, _result, nil), do: updates

  defp maybe_add_prefixed_keys(updates, _node_id, result, prefix) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, map} when is_map(map) ->
        prefixed =
          Enum.reduce(map, %{}, fn {k, v}, acc ->
            Map.put(acc, "#{prefix}.#{k}", v)
          end)

        Map.merge(updates, prefixed)

      _ ->
        updates
    end
  end

  defp maybe_add_prefixed_keys(updates, _node_id, result, prefix) when is_map(result) do
    prefixed =
      Enum.reduce(result, %{}, fn {k, v}, acc ->
        Map.put(acc, "#{prefix}.#{k}", v)
      end)

    Map.merge(updates, prefixed)
  end

  defp maybe_add_prefixed_keys(updates, _node_id, _result, _prefix), do: updates
end
