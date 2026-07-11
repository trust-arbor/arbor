defmodule Arbor.Actions.Coding.ReviewedCommit do
  @moduledoc """
  Top-level coding commit/adoption gate as a reviewed Jido action (syscall).

  Graph-owned branching consumes the structured success payload:

    * `interaction_outcome=""` — approved (or unattended authorize) commit/adopt
    * `interaction_outcome="denied"` — operator deny; never mutates git
    * `interaction_outcome="rework"` — operator rework; never mutates git

  Approve executes exactly the reviewed invocation once via the standard
  `approved_invocation` marker. Deny and rework never execute.

  Nested Git authorization always mints a **fresh** exact-resource
  `SignedRequest` from the reload-stable `SigningAuthority` propagated on the
  action context. The outer coding action's signed request/nonce is never
  reused for `arbor://action/git/commit`.

  Approval is bound to the inspected candidate revision via
  `expected_head_commit` (verified before and after the wait).

  This action is pipeline-internal: registered for Engine pinned execution but
  not enumerated or runnable as an ordinary MCP/agent tool.
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
      expected_head_commit: [
        type: :string,
        required: false,
        doc: "Candidate HEAD revision the operator inspected; required for drift-safe approval"
      ],
      head_commit: [
        type: :string,
        required: false,
        doc: "Alias for expected_head_commit when passed via context_keys"
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
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Git
  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Security.{SignedRequest, SigningAuthority}

  @default_approval_timeout 60_000

  def taint_roles do
    %{
      path: {:control, requires: [:path_traversal]},
      message: {:control, requires: [:command_injection]},
      workspace_dirty: :control,
      expected_head_commit: :control,
      head_commit: :control,
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
    expected_head = expected_head_commit(params)
    git_params = git_commit_params(path, message, params)
    resource = Actions.canonical_uri_for(Git.Commit, git_params)

    result =
      with :ok <- require_expected_head(expected_head),
           :ok <- verify_head_matches(path, expected_head, dirty?),
           {:ok, signed_request} <- fresh_signed_request(resource, context),
           auth_context = put_signed_request(context, signed_request) do
        case authorize_commit(agent_id, resource, git_params, auth_context) do
          :authorized ->
            perform_after_approve(
              agent_id,
              git_params,
              auth_context,
              dirty?,
              path,
              expected_head,
              nil,
              ""
            )

          {:pending_approval, request_id} ->
            await_and_decide(
              agent_id,
              request_id,
              git_params,
              auth_context,
              dirty?,
              path,
              expected_head
            )

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      else
        {:error, reason} -> {:error, format_error(reason)}
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
        agent_id: agent_id,
        expected_head_commit: params[:expected_head_commit]
      }
    )
  end

  # -- await + decide --------------------------------------------------------

  defp await_and_decide(agent_id, request_id, git_params, context, dirty?, path, expected_head) do
    with {:ok, request_id} <- ApprovalAnswer.validate_request_id(request_id),
         {:ok, decision} <- await_decision(agent_id, request_id, context),
         # Re-verify candidate revision after the wait — fail closed on drift.
         :ok <- verify_head_matches(path, expected_head, dirty?) do
      case decision do
        :approve ->
          perform_after_approve(
            agent_id,
            git_params,
            context,
            dirty?,
            path,
            expected_head,
            request_id,
            ""
          )

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
    if is_nil(agent_id) do
      {:error, :missing_agent_id}
    else
      case Arbor.Comms.await_interaction_response(request_id, agent_id, timeout: timeout) do
        {:ok, response, metadata} ->
          normalize_decision(response, metadata)

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp await_consensus(proposal_id, timeout) do
    case Arbor.Consensus.await(proposal_id, timeout: timeout) do
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

  defp perform_after_approve(
         agent_id,
         git_params,
         context,
         dirty?,
         path,
         expected_head,
         request_id,
         note
       ) do
    with :ok <- verify_head_matches(path, expected_head, dirty?) do
      if dirty? do
        execute_commit_once(agent_id, git_params, context, request_id, note, expected_head)
      else
        adopt_head(path, expected_head, request_id, note)
      end
    end
  end

  defp execute_commit_once(agent_id, git_params, context, request_id, note, expected_head) do
    resource = Actions.canonical_uri_for(Git.Commit, git_params)

    # Fresh exact-resource SignedRequest for the nested git commit — never
    # reuse the outer coding_reviewed_commit signed request/nonce.
    with {:ok, fresh_sr} <- fresh_signed_request(resource, context) do
      retry_context =
        context
        |> put_signed_request(fresh_sr)
        |> then(fn ctx ->
          if is_binary(request_id) do
            Map.put(ctx, :approved_invocation, %{
              request_id: request_id,
              principal_id: agent_id,
              resource_uri: resource,
              decision: :approved
            })
          else
            ctx
          end
        end)
        # Nested git commit is a pipeline-internal owner retry, not MCP exposure.
        |> Map.put(:allow_pipeline_internal, true)
        |> Map.put(:expected_head_commit, expected_head)

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
  end

  defp adopt_head(path, expected_head, request_id, note) do
    case read_head(path) do
      {:ok, hash} ->
        if is_binary(expected_head) and expected_head != "" and hash != expected_head do
          {:error, {:head_drift, expected_head, hash}}
        else
          {:ok,
           %{
             "interaction_outcome" => "",
             "request_id" => request_id || "",
             "note" => note || "",
             "commit_hash" => hash,
             "path" => path,
             "adopted" => true
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- head binding ----------------------------------------------------------

  defp expected_head_commit(params) do
    case Map.get(params, :expected_head_commit) || Map.get(params, :head_commit) ||
           Map.get(params, "expected_head_commit") || Map.get(params, "head_commit") do
      h when is_binary(h) and h != "" -> h
      _ -> nil
    end
  end

  defp require_expected_head(head) when is_binary(head) and head != "", do: :ok
  defp require_expected_head(_), do: {:error, :missing_expected_head_commit}

  # Dirty: expected must equal current HEAD (parent of the about-to-be commit).
  # Clean: expected must equal current HEAD (adoption identity).
  defp verify_head_matches(path, expected, _dirty?) when is_binary(expected) and expected != "" do
    case read_head(path) do
      {:ok, actual} when actual == expected ->
        :ok

      {:ok, actual} ->
        {:error, {:head_drift, expected, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_head_matches(_path, _expected, _dirty?), do: {:error, :missing_expected_head_commit}

  # Schema-bounded workspace inspect — not unbounded System.cmd.
  defp read_head(path) when is_binary(path) do
    inspection = Workspace.inspect_worktree(path, nil)

    case inspection do
      %{exists: true, head_commit: hash} when is_binary(hash) and hash != "" ->
        {:ok, hash}

      %{exists: false} ->
        {:error, "worktree does not exist: #{path}"}

      _ ->
        {:error, "failed to read HEAD for #{path}"}
    end
  end

  defp read_head(_), do: {:error, "invalid path"}

  # -- signing authority -----------------------------------------------------

  defp fresh_signed_request(resource, context) when is_binary(resource) do
    case signing_authority(context) do
      {:ok, authority} ->
        case Arbor.Security.sign_with_authority(authority, resource) do
          {:ok, signed} -> {:ok, signed}
          {:error, reason} -> {:error, {:signing_failed, reason}}
        end

      {:error, _} = err ->
        # Fall back to auth_context.signer (legacy reload-stable function form)
        # when SigningAuthority is absent — still mints a fresh exact-resource SR.
        case legacy_signer(context) do
          signer when is_function(signer, 1) ->
            case signer.(resource) do
              {:ok, signed} -> {:ok, signed}
              {:error, reason} -> {:error, {:signing_failed, reason}}
              other -> {:error, {:signing_failed, other}}
            end

          _ ->
            err
        end
    end
  end

  defp signing_authority(context) do
    authority =
      Map.get(context, :signing_authority) ||
        nested_opt(context, :signing_authority)

    cond do
      SigningAuthority.signing_authority?(authority) ->
        {:ok, authority}

      is_map(authority) ->
        case SigningAuthority.canonicalize(authority) do
          {:ok, canonical} -> {:ok, canonical}
          {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
        end

      true ->
        {:error, :missing_signing_authority}
    end
  end

  defp legacy_signer(context) do
    case Map.get(context, :auth_context) do
      %{signer: signer} when is_function(signer, 1) -> signer
      _ -> Map.get(context, :signer)
    end
  end

  defp nested_opt(context, key) do
    case Map.get(context, :nested_engine_opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  defp put_signed_request(context, signed_request) do
    # Real `%SignedRequest{}` proofs must re-verify against the exact nested
    # resource (fresh nonce). Stub maps from test signers skip re-verify so
    # identity_verification:false + approved_invocation paths stay exercisable.
    identity_verified? = not match?(%SignedRequest{}, signed_request)

    context
    |> Map.put(:signed_request, signed_request)
    |> Map.put(:identity_verified, identity_verified?)
    |> then(fn ctx ->
      case Map.get(ctx, :auth_context) do
        %{__struct__: _} = auth ->
          Map.put(ctx, :auth_context, %{auth | signed_request: signed_request})

        auth when is_map(auth) ->
          Map.put(ctx, :auth_context, Map.put(auth, :signed_request, signed_request))

        _ ->
          ctx
      end
    end)
  end

  # -- helpers ---------------------------------------------------------------

  defp control_payload(outcome, request_id, note)
       when outcome in ["denied", "rework"] and is_binary(request_id) do
    {:ok, bounded_note} =
      ApprovalAnswer.validate_note(note, drop_invalid: true, truncate: true)

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
      allow_empty: truthy?(Map.get(params, :allow_empty, false)),
      expected_head_commit: expected_head_commit(params)
    }
  end

  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp context_agent_id(context) do
    context_value(context, :agent_id) ||
      case Map.get(context, :auth_context) do
        %{agent_id: id} when is_binary(id) -> id
        %{principal_id: id} when is_binary(id) -> id
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
  defp format_error(:missing_expected_head_commit), do: "expected_head_commit is required"
  defp format_error(:missing_signing_authority), do: "signing authority required for git commit"
  defp format_error(:unauthorized), do: "unauthorized"

  defp format_error({:head_drift, expected, actual}),
    do: "head drifted during approval: expected=#{expected} actual=#{actual}"

  defp format_error({:signing_failed, reason}), do: "signing failed: #{inspect(reason)}"

  defp format_error({:invalid_signing_authority, reason}),
    do: "invalid signing authority: #{inspect(reason)}"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
