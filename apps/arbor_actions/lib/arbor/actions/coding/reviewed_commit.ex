defmodule Arbor.Actions.Coding.ReviewedCommit do
  @moduledoc """
  Top-level coding commit/adoption gate as a reviewed Jido action (syscall).

  Graph-owned branching consumes the structured success payload:

    * `interaction_outcome=""` — approved (or unattended authorize) commit/adopt
    * `interaction_outcome="denied"` — operator deny; never mutates git
    * `interaction_outcome="rework"` — operator rework; never mutates git

  Approve executes exactly the reviewed invocation once via the standard
  `approved_invocation` marker. Deny and rework never execute.

  This action is pipeline-internal: it is registered for graph execution but
  tagged so ordinary LLM tool discovery does not surface it as a free-form tool.
  """

  use Jido.Action,
    name: "coding_reviewed_commit",
    description:
      "Request operator approval then commit or adopt a coding worktree change (pipeline-internal)",
    category: "coding",
    tags: ["coding", "git", "approval", "pipeline_internal"],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Path to the Git worktree / repository"
      ],
      message: [
        type: :string,
        required: true,
        doc: "Commit message used when the worktree is dirty"
      ],
      workspace_dirty: [
        type: :boolean,
        default: true,
        doc: "When true, commit changes; when false, adopt HEAD after approval"
      ],
      all: [
        type: :boolean,
        default: true,
        doc: "Stage all modified files before commit (dirty path only)"
      ],
      allow_empty: [
        type: :boolean,
        default: false,
        doc: "Allow empty commits (dirty path only)"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Git
  alias Arbor.Contracts.Comms.ApprovalAnswer

  @default_approval_timeout 60_000

  def taint_roles do
    %{
      path: {:control, requires: [:path_traversal]},
      message: {:control, requires: [:command_injection]},
      workspace_dirty: :control,
      all: :control,
      allow_empty: :control
    }
  end

  def effect_class, do: :local_write

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(%{path: path, message: message} = params, context) do
    Actions.emit_started(__MODULE__, %{path: path})

    agent_id = context_agent_id(context)
    dirty? = truthy?(Map.get(params, :workspace_dirty, true))
    git_params = git_commit_params(path, message, params)
    resource = Actions.canonical_uri_for(Git.Commit, git_params)

    result =
      case authorize_commit(agent_id, resource, git_params, context) do
        :authorized ->
          perform_after_approve(agent_id, git_params, context, dirty?, path, nil, "")

        {:pending_approval, request_id} ->
          await_and_decide(agent_id, request_id, git_params, context, dirty?, path)

        {:error, reason} ->
          {:error, format_error(reason)}
      end

    case result do
      {:ok, payload} = ok ->
        Actions.emit_completed(__MODULE__, %{
          path: path,
          interaction_outcome: payload["interaction_outcome"]
        })

        ok

      {:error, reason} = err ->
        Actions.emit_failed(__MODULE__, reason)
        err
    end
  end

  # -- authorize -------------------------------------------------------------

  defp authorize_commit(agent_id, resource, params, context) do
    auth_opts = build_auth_opts(agent_id, resource, params, context)

    case Arbor.Trust.authorize(agent_id, resource, :execute, auth_opts) do
      result
      when result == {:ok, :authorized} or
             (is_tuple(result) and elem(result, 0) == :ok and elem(result, 1) == :authorized) ->
        :authorized

      {:ok, :pending_approval, proposal_id} when is_binary(proposal_id) ->
        {:pending_approval, proposal_id}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_authorize_result, other}}
    end
  end

  defp build_auth_opts(agent_id, resource, params, context) do
    signed_request = Map.get(context, :signed_request)

    []
    |> maybe_put(:signed_request, signed_request)
    |> maybe_put(:task_id, context_value(context, :task_id))
    |> maybe_put(:session_id, context_value(context, :session_id))
    |> maybe_put(:approved_invocation, Map.get(context, :approved_invocation))
    |> Keyword.put(
      :approval_context,
      %{
        action: "coding_reviewed_commit",
        resource_uri: resource,
        path: params[:path],
        message: params[:message],
        agent_id: agent_id
      }
    )
  end

  # -- await + decide --------------------------------------------------------

  defp await_and_decide(agent_id, request_id, git_params, context, dirty?, path) do
    with {:ok, request_id} <- ApprovalAnswer.validate_request_id(request_id),
         {:ok, decision} <- await_decision(agent_id, request_id, context) do
      case decision do
        :approve ->
          perform_after_approve(agent_id, git_params, context, dirty?, path, request_id, "")

        {:deny, note} ->
          {:ok, control_payload("denied", request_id, note)}

        {:rework, note} ->
          {:ok, control_payload("rework", request_id, note)}
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp await_decision(agent_id, request_id, context) do
    timeout = approval_timeout(context)

    cond do
      interaction_request?(request_id) ->
        await_interaction(agent_id, request_id, timeout)

      true ->
        await_consensus(request_id, timeout)
    end
  end

  defp await_interaction(agent_id, request_id, timeout) do
    router = interaction_router()

    cond do
      is_nil(agent_id) ->
        {:error, :missing_agent_id}

      function_exported?(router, :await_response, 3) ->
        case apply(router, :await_response, [request_id, agent_id, [timeout: timeout]]) do
          {:ok, response, metadata} ->
            normalize_decision(response, metadata)

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :interaction_router_unavailable}
    end
  end

  defp await_consensus(proposal_id, timeout) do
    consensus = Module.concat([:Arbor, :Consensus])

    if Code.ensure_loaded?(consensus) and function_exported?(consensus, :await, 2) do
      case apply(consensus, :await, [proposal_id, [timeout: timeout]]) do
        {:ok, decision} when is_map(decision) ->
          case ApprovalAnswer.normalize_consensus_decision(decision) do
            {:ok, :approve} -> {:ok, :approve}
            {:ok, :rework, note} -> {:ok, {:rework, note}}
            {:ok, :deny, note} -> {:ok, {:deny, note}}
            {:error, reason} -> {:error, reason}
          end

        {:ok, :approved} ->
          {:ok, :approve}

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :consensus_unavailable}
    end
  end

  defp normalize_decision(response, metadata) do
    case ApprovalAnswer.normalize(response, metadata) do
      {:ok, :approve} -> {:ok, :approve}
      {:ok, :rework, note} -> {:ok, {:rework, note}}
      {:ok, :deny, note} -> {:ok, {:deny, note}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- execute once after approve --------------------------------------------

  defp perform_after_approve(agent_id, git_params, context, dirty?, path, request_id, note) do
    if dirty? do
      execute_commit_once(agent_id, git_params, context, request_id, note)
    else
      adopt_head(path, request_id, note)
    end
  end

  defp execute_commit_once(agent_id, git_params, context, request_id, note) do
    resource = Actions.canonical_uri_for(Git.Commit, git_params)

    retry_context =
      if is_binary(request_id) do
        Map.put(context, :approved_invocation, %{
          request_id: request_id,
          principal_id: agent_id,
          resource_uri: resource,
          decision: :approved
        })
      else
        context
      end

    case Actions.authorize_and_execute(agent_id, Git.Commit, git_params, retry_context) do
      {:ok, result} when is_map(result) ->
        {:ok,
         %{
           "interaction_outcome" => "",
           "request_id" => request_id || "",
           "note" => note || "",
           "commit_hash" =>
             stringify(Map.get(result, :commit_hash) || Map.get(result, "commit_hash")),
           "path" =>
             stringify(Map.get(result, :path) || Map.get(result, "path") || git_params[:path]),
           "message" =>
             stringify(
               Map.get(result, :message) || Map.get(result, "message") || git_params[:message]
             )
         }}

      {:ok, :pending_approval, retry_id} ->
        {:error, "still requires approval after grant: #{retry_id}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "approved commit failed: #{inspect(reason)}"}
    end
  end

  defp adopt_head(path, request_id, note) do
    case head_commit(path) do
      {:ok, hash} ->
        {:ok,
         %{
           "interaction_outcome" => "",
           "request_id" => request_id || "",
           "note" => note || "",
           "commit_hash" => hash,
           "path" => path,
           "adopted" => true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp head_commit(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        hash = String.trim(output)
        if hash != "", do: {:ok, hash}, else: {:error, "empty HEAD"}

      {output, _code} ->
        {:error, "failed to read HEAD: #{String.trim(output)}"}
    end
  end

  defp head_commit(_), do: {:error, "invalid path"}

  # -- helpers ---------------------------------------------------------------

  defp control_payload(outcome, request_id, note)
       when outcome in ["denied", "rework"] and is_binary(request_id) do
    {:ok, bounded_note} = ApprovalAnswer.validate_note(note, drop_invalid: true)

    %{
      "interaction_outcome" => outcome,
      "request_id" => request_id,
      "note" => bounded_note,
      "commit_hash" => "",
      "path" => "",
      "message" => ""
    }
  end

  defp git_commit_params(path, message, params) do
    %{
      path: path,
      message: message,
      all: truthy?(Map.get(params, :all, true)),
      allow_empty: truthy?(Map.get(params, :allow_empty, false))
    }
  end

  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp interaction_router, do: Module.concat([:Arbor, :Comms, :InteractionRouter])

  defp context_agent_id(context) do
    context_value(context, :agent_id) ||
      case Map.get(context, :auth_context) do
        %{agent_id: id} when is_binary(id) -> id
        _ -> nil
      end
  end

  defp context_value(context, key) when is_atom(key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end

  defp approval_timeout(context) do
    case context_value(context, :approval_timeout_ms) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Application.get_env(
          :arbor_actions,
          :approval_timeout_ms,
          Application.get_env(
            :arbor_orchestrator,
            :approval_timeout_ms,
            @default_approval_timeout
          )
        )
    end
  end

  defp truthy?(v) when v in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp stringify(nil), do: ""
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)

  defp format_error(:timeout), do: "approval timed out"
  defp format_error(:missing_agent_id), do: "approval wait requires agent_id"
  defp format_error(:unauthorized), do: "unauthorized"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
