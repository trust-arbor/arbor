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
    - `context_keys` — comma-separated context keys to merge as action params
    - `project_interaction_control` — reviewed opt-in (true) that projects a
      tagged ActionsExecutor `{:control, map}` into a successful branchable
      Outcome. Only valid for the coding `git_commit` gate; elsewhere fails
      closed as an ordinary action failure so denial never becomes success.
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}

  alias Arbor.Orchestrator.Handlers.{
    ShellHandler,
    ToolHandler
  }

  # Only the reviewed coding git_commit gate may turn interaction control
  # outcomes into a successful branchable Outcome. Semantic preflight also
  # rejects the opt-in on any other node/action.
  @interaction_control_opt_in_attr "project_interaction_control"
  @interaction_control_allowed_action "git_commit"
  @interaction_control_outcomes MapSet.new(["rework", "denied"])

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

      action_args = build_action_args(node.id, node.attrs, context)

      output_prefix = Map.get(node.attrs, "output_prefix")

      # Preserve the aggregate taint for operation-level authorization, egress,
      # and telemetry while also carrying each runtime parameter's exact label
      # to the action enforcement boundary. Static attr args are author-written;
      # only context_keys values can be runtime-tainted.
      context_keys = consumed_context_keys(node.attrs)
      input_taint = Context.worst_taint(context, context_keys)

      executor_opts =
        [
          agent_id: agent_id,
          caller_id: caller_id,
          author_id: author_id,
          signer: Keyword.get(opts, :signer),
          task_id: task_id,
          session_id: session_id,
          taint: input_taint
        ]
        |> maybe_put_param_taint(context, context_keys)
        |> maybe_put_execution_binding(authority)
        |> maybe_put_nested_engine_controls(opts, authority)
        |> maybe_put_approval_timeout(opts)

      try do
        case executor.execute(action_name, action_args, workdir, executor_opts) do
          {:ok, result} ->
            updates =
              flatten_context_updates(node.id, result)
              |> maybe_add_prefixed_keys(node.id, result, output_prefix)
              |> maybe_clear_interaction_control(node, action_name, output_prefix)

            %Outcome{
              status: :success,
              notes: "Action #{action_name} executed",
              context_updates: updates,
              # Provenance (Phase 1): if this action is an ingress (e.g. web
              # fetch -> :untrusted, or a foreign-path file read), label its
              # output keys so downstream nodes that consume them are gated at
              # control params. Params let path-based actions decide provenance.
              output_taint: action_output_taint(executor, action_name, action_args)
            }

          {:control, payload} ->
            project_interaction_control(node, action_name, payload, output_prefix)

          {:error, reason} ->
            %Outcome{
              status: :fail,
              failure_reason: "Action #{action_name} failed: #{reason}"
            }
        end
      catch
        :exit, reason ->
          %Outcome{
            status: :fail,
            failure_reason: "Action #{action_name} process error: #{inspect(reason)}"
          }
      end
    else
      %Outcome{
        status: :fail,
        failure_reason: "Arbor.Orchestrator.ActionsExecutor not available"
      }
    end
  end

  # Project a tagged interaction control payload into a successful Outcome only
  # for the reviewed git_commit opt-in. Without that exact static opt-in the
  # control result remains a failure so LLM/direct paths stay honest.
  defp project_interaction_control(node, action_name, payload, output_prefix) do
    if interaction_control_projection_allowed?(node, action_name) do
      case normalize_control_payload(payload) do
        {:ok, clean} ->
          updates =
            flatten_context_updates(node.id, Jason.encode!(clean))
            |> maybe_add_prefixed_keys(node.id, Jason.encode!(clean), output_prefix)

          %Outcome{
            status: :success,
            notes: "Action #{action_name} interaction control: #{clean["interaction_outcome"]}",
            context_updates: updates
          }

        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason:
              "Action #{action_name} interaction control rejected: #{inspect(reason)}"
          }
      end
    else
      outcome = control_payload_outcome(payload)

      %Outcome{
        status: :fail,
        failure_reason:
          "Action #{action_name} was #{outcome} by the operator" <>
            control_request_suffix(payload)
      }
    end
  end

  defp interaction_control_projection_allowed?(node, action_name) do
    opt_in? = Map.get(node.attrs, @interaction_control_opt_in_attr) in ["true", true, "1", 1]
    action_name == @interaction_control_allowed_action and opt_in?
  end

  defp maybe_clear_interaction_control(updates, node, action_name, output_prefix) do
    if interaction_control_projection_allowed?(node, action_name) do
      # Prior rework/deny control keys must not stick around after a fresh
      # successful commit on the same output_prefix.
      prefix = output_prefix || "exec.#{node.id}"

      updates
      |> Map.put("#{prefix}.interaction_outcome", "")
      |> Map.put("#{prefix}.request_id", "")
      |> Map.put("#{prefix}.note", "")
    else
      updates
    end
  end

  defp normalize_control_payload(payload) when is_map(payload) do
    outcome =
      stringify_control_field(
        Map.get(payload, "interaction_outcome") || Map.get(payload, :interaction_outcome)
      )

    request_id =
      stringify_control_field(Map.get(payload, "request_id") || Map.get(payload, :request_id))

    note = stringify_control_field(Map.get(payload, "note") || Map.get(payload, :note) || "")

    cond do
      outcome not in @interaction_control_outcomes ->
        {:error, :invalid_interaction_outcome}

      not is_binary(request_id) or request_id == "" ->
        {:error, :missing_request_id}

      not String.valid?(request_id) or not String.valid?(note) ->
        {:error, :invalid_utf8}

      true ->
        {:ok,
         %{
           "interaction_outcome" => outcome,
           "request_id" => request_id,
           "note" => note
         }}
    end
  end

  defp normalize_control_payload(_), do: {:error, :malformed_control_payload}

  defp stringify_control_field(value) when is_binary(value), do: value
  defp stringify_control_field(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_control_field(_), do: nil

  defp control_payload_outcome(payload) when is_map(payload) do
    case Map.get(payload, "interaction_outcome") || Map.get(payload, :interaction_outcome) do
      "rework" -> "sent for rework"
      :rework -> "sent for rework"
      "denied" -> "denied"
      :denied -> "denied"
      _ -> "rejected"
    end
  end

  defp control_payload_outcome(_), do: "rejected"

  defp control_request_suffix(payload) when is_map(payload) do
    case Map.get(payload, "request_id") || Map.get(payload, :request_id) do
      id when is_binary(id) and id != "" -> ". Request ID: #{id}."
      _ -> "."
    end
  end

  defp control_request_suffix(_), do: "."

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
  defp build_action_args(node_id, attrs, context) do
    # 1. Collect arg.*/param.* prefixed attrs
    attr_args = parse_attr_args(node_id, attrs)

    # 2. If context_keys attr is set, merge context values as params
    context_args =
      case Map.get(attrs, "context_keys") do
        nil ->
          %{}

        keys_csv ->
          keys_csv
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce(%{}, fn key, acc ->
            case Context.get(context, key) do
              nil ->
                # Silent param loss is the bug: action runs with a
                # partial param set and the operator gets no signal.
                # Warn so the missing key is visible in logs even
                # when the action's eventual error doesn't point here.
                Logger.warning(
                  "[ExecHandler] #{node_id}: context_keys references " <>
                    "\"#{key}\" but no such key in context; param will " <>
                    "be missing from action call"
                )

                acc

              value ->
                Map.put(acc, key, value)
            end
          end)
      end

    Map.merge(attr_args, context_args)
  end

  # The context keys whose values are interpolated into this action's params.
  # These are the only runtime-tainted inputs (static arg.*/param.* attrs are
  # author-written and trusted). Mirrors the context_keys parsing in
  # build_action_args/3.
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

  defp maybe_put_param_taint(opts, _context, []), do: opts

  defp maybe_put_param_taint(opts, context, context_keys) do
    param_taint =
      Enum.reduce(context_keys, %{}, fn key, acc ->
        case Context.get(context, key) do
          nil -> acc
          _value -> Map.put(acc, key, Context.taint_label(context, key))
        end
      end)

    Keyword.put(opts, :param_taint, param_taint)
  end

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

  # Approval timeout is Engine control data, never a node attr or context
  # value. Re-bound it against the run wall clock before crossing into the
  # action executor, and mark the internal source so direct action callers
  # cannot opt into the longer coding wait accidentally.
  defp maybe_put_approval_timeout(executor_opts, engine_opts) do
    requested_ms = Keyword.get(engine_opts, :approval_timeout_ms)
    wall_clock_ms = Keyword.get(engine_opts, :timeout)

    case Config.bounded_coding_approval_timeout_ms(requested_ms, wall_clock_ms) do
      {:ok, timeout_ms} ->
        executor_opts
        |> Keyword.put(:approval_timeout_ms, timeout_ms)
        |> Keyword.put(:approval_timeout_source, __MODULE__)

      :error ->
        executor_opts
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
