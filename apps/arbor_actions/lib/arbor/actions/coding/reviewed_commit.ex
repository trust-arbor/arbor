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

  Approval is bound to the exact inspected candidate content via:

    * `expected_head_commit` — HEAD the operator inspected
    * `expected_workspace_fingerprint` — bounded worktree digest (HEAD + index +
      unstaged/untracked content) from `Workspace.worktree_fingerprint/2`
    * `expected_tree_oid` — exact `add -A` committable tree when a prior
      validator produced one (default/cross_app: `validation.validated_tree_oid`)

  HEAD and fingerprint are always required from the graph. When a prior
  validated tree is present it is compared fail-closed. When no prior
  validator tree can exist (security_regression commits before its
  two-revision validator), this action computes the exact committable tree
  via `Mix.committable_tree_binding/1` before authorization, freezes it in
  the approval context, and re-verifies it after the wait, immediately
  before mutation, and against the resulting commit tree.

  Ambiguous mixed mode is rejected when a workspace lease is present:
  `workspace_dirty=true` while HEAD has already advanced past the lease base
  (self-commit plus residual dirt). Clean self-commit adoption and dirty
  uncommitted changes from the lease base remain allowed.

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
      expected_workspace_fingerprint: [
        type: :string,
        required: false,
        doc: "Inspected worktree fingerprint digest; required for content-bound approval"
      ],
      workspace_fingerprint: [
        type: :string,
        required: false,
        doc: "Alias for expected_workspace_fingerprint when passed via context_keys"
      ],
      expected_tree_oid: [
        type: :string,
        required: false,
        doc:
          "Upstream validated committable tree OID when a prior validator ran; when absent, computed and frozen here before authorization"
      ],
      validated_tree_oid: [
        type: :string,
        required: false,
        doc: "Alias for expected_tree_oid when passed via context_keys"
      ],
      workspace_id: [
        type: :string,
        required: false,
        doc: "Active workspace lease that binds linked-worktree Git storage authority"
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
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, SigningAuthority}

  @default_approval_timeout 60_000
  @git_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @fingerprint_re ~r/\Asha256:[0-9a-f]{64}\z/

  def taint_roles do
    %{
      path: {:control, requires: [:path_traversal]},
      message: {:control, requires: [:command_injection]},
      workspace_dirty: :control,
      expected_head_commit: :control,
      head_commit: :control,
      expected_workspace_fingerprint: :control,
      workspace_fingerprint: :control,
      expected_tree_oid: :control,
      validated_tree_oid: :control,
      workspace_id: :control,
      all: :control,
      allow_empty: :control
    }
  end

  def effect_class, do: :local_write

  @doc """
  Nested actions this composite may invoke under its own authorization path.
  """
  @spec execution_dependencies() :: [module()]
  def execution_dependencies, do: [Git.Commit]

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(%{path: path, message: message} = params, context) do
    Actions.emit_started(__MODULE__, %{path: path})

    agent_id = context_agent_id(context)
    dirty? = truthy?(Map.get(params, :workspace_dirty, true))
    workspace_id = workspace_id(params)

    result =
      with {:ok, bindings} <- resolve_candidate_bindings(path, params),
           git_params = git_commit_params(path, message, params, bindings),
           resource = Actions.canonical_uri_for(Git.Commit, git_params),
           :ok <- verify_workspace_binding(path, workspace_id, context),
           :ok <- reject_ambiguous_dirty_advanced_head(path, dirty?, workspace_id, context),
           :ok <- verify_candidate_content(path, bindings),
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
              workspace_id,
              bindings,
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
              workspace_id,
              bindings
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
        expected_head_commit: params[:expected_head_commit],
        expected_workspace_fingerprint: params[:expected_workspace_fingerprint],
        expected_tree_oid: params[:expected_tree_oid]
      }
    )
  end

  # -- await + decide --------------------------------------------------------

  defp await_and_decide(
         agent_id,
         request_id,
         git_params,
         context,
         dirty?,
         path,
         workspace_id,
         bindings
       ) do
    with {:ok, request_id} <- ApprovalAnswer.validate_request_id(request_id),
         {:ok, decision} <- await_decision(agent_id, request_id, context),
         :ok <- verify_workspace_binding(path, workspace_id, context),
         :ok <- reject_ambiguous_dirty_advanced_head(path, dirty?, workspace_id, context),
         # Re-verify exact candidate content after the wait — fail closed on drift.
         :ok <- verify_candidate_content(path, bindings) do
      case decision do
        :approve ->
          perform_after_approve(
            agent_id,
            git_params,
            context,
            dirty?,
            path,
            workspace_id,
            bindings,
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
         workspace_id,
         bindings,
         request_id,
         note
       ) do
    with :ok <- verify_workspace_binding(path, workspace_id, context),
         :ok <- reject_ambiguous_dirty_advanced_head(path, dirty?, workspace_id, context),
         :ok <- verify_candidate_content(path, bindings) do
      if dirty? do
        execute_commit_once(
          agent_id,
          git_params,
          context,
          workspace_id,
          request_id,
          note,
          bindings
        )
      else
        adopt_head(path, bindings, request_id, note)
      end
    end
  end

  defp execute_commit_once(
         agent_id,
         git_params,
         context,
         workspace_id,
         request_id,
         note,
         bindings
       ) do
    resource = Actions.canonical_uri_for(Git.Commit, git_params)

    # Fresh exact-resource SignedRequest for the nested git commit — never
    # reuse the outer coding_reviewed_commit signed request/nonce.
    with {:ok, fresh_sr} <- fresh_signed_request(resource, context) do
      retry_context =
        context
        |> put_signed_request(fresh_sr)
        |> maybe_drop_legacy_signed_request(fresh_sr)
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
        |> Map.put(:expected_head_commit, bindings.head)
        |> Map.put(:expected_tree_oid, bindings.tree_oid)

      execute_result =
        with_workspace_storage_authority(workspace_id, git_params.path, context, fn ->
          Actions.authorize_and_execute(agent_id, Git.Commit, git_params, retry_context)
        end)

      case execute_result do
        {:ok, result} when is_map(result) ->
          commit_hash =
            stringify(Map.get(result, :commit_hash) || Map.get(result, "commit_hash"))

          with :ok <-
                 verify_resulting_commit_tree(git_params.path, commit_hash, bindings.tree_oid) do
            {:ok,
             %{
               "interaction_outcome" => "",
               "request_id" => request_id || "",
               "note" => note || "",
               "commit_hash" => commit_hash,
               "path" =>
                 stringify(Map.get(result, :path) || Map.get(result, "path") || git_params[:path]),
               "message" =>
                 stringify(
                   Map.get(result, :message) || Map.get(result, "message") ||
                     git_params[:message]
                 )
             }}
          end

        {:ok, :pending_approval, retry_id} ->
          {:error, "still requires approval after grant: #{retry_id}"}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "approved commit failed: #{inspect(reason)}"}
      end
    end
  end

  defp adopt_head(path, bindings, request_id, note) do
    with :ok <- verify_candidate_content(path, bindings),
         {:ok, hash} <- read_head(path),
         :ok <- verify_resulting_commit_tree(path, hash, bindings.tree_oid) do
      if hash != bindings.head do
        {:error, {:head_drift, bindings.head, hash}}
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
    end
  end

  # -- candidate content binding ---------------------------------------------

  # Resolve HEAD + fingerprint (always required from the graph) and the
  # committable tree: prefer an upstream validated tree when present; otherwise
  # compute and freeze it here so commit-before-validate profiles stay bound.
  defp resolve_candidate_bindings(path, params) do
    head = param_string(params, [:expected_head_commit, :head_commit])

    fingerprint =
      param_string(params, [:expected_workspace_fingerprint, :workspace_fingerprint])

    upstream_tree = param_string(params, [:expected_tree_oid, :validated_tree_oid])

    with :ok <-
           require_git_oid(head, :missing_expected_head_commit, :invalid_expected_head_commit),
         :ok <- require_fingerprint(fingerprint),
         {:ok, tree_oid, tree_source} <- resolve_tree_oid(path, upstream_tree) do
      {:ok,
       %{
         head: head,
         fingerprint: fingerprint,
         tree_oid: tree_oid,
         tree_source: tree_source
       }}
    end
  end

  defp resolve_tree_oid(_path, tree_oid) when is_binary(tree_oid) and tree_oid != "" do
    case require_git_oid(tree_oid, :missing_expected_tree_oid, :invalid_expected_tree_oid) do
      :ok -> {:ok, tree_oid, :upstream}
      {:error, _} = error -> error
    end
  end

  defp resolve_tree_oid(path, _absent) when is_binary(path) do
    case MixAction.committable_tree_binding(path) do
      {:ok, %{tree_oid: tree_oid}} when is_binary(tree_oid) and tree_oid != "" ->
        case require_git_oid(tree_oid, :missing_expected_tree_oid, :invalid_expected_tree_oid) do
          :ok -> {:ok, tree_oid, :computed}
          {:error, _} = error -> error
        end

      {:ok, _} ->
        {:error, :missing_expected_tree_oid}

      {:error, reason} ->
        {:error, {:validated_tree_binding_failed, reason}}
    end
  end

  defp resolve_tree_oid(_path, _absent), do: {:error, :missing_expected_tree_oid}

  defp param_string(params, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp workspace_id(params) do
    case Map.get(params, :workspace_id) || Map.get(params, "workspace_id") do
      id when is_binary(id) and id != "" -> id
      nil -> nil
      _ -> :invalid
    end
  end

  defp require_git_oid(value, missing, invalid) do
    cond do
      not is_binary(value) or value == "" -> {:error, missing}
      Regex.match?(@git_oid_re, value) -> :ok
      true -> {:error, invalid}
    end
  end

  defp require_fingerprint(value) when is_binary(value) and value != "" do
    if Regex.match?(@fingerprint_re, value),
      do: :ok,
      else: {:error, :invalid_expected_workspace_fingerprint}
  end

  defp require_fingerprint(_), do: {:error, :missing_expected_workspace_fingerprint}

  defp verify_candidate_content(path, bindings) do
    with :ok <- verify_head_matches(path, bindings.head),
         :ok <- verify_fingerprint_matches(path, bindings.head, bindings.fingerprint),
         :ok <- verify_tree_matches(path, bindings.tree_oid) do
      :ok
    end
  end

  defp verify_head_matches(path, expected) when is_binary(expected) and expected != "" do
    case read_head(path) do
      {:ok, actual} when actual == expected ->
        :ok

      {:ok, actual} ->
        {:error, {:head_drift, expected, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_head_matches(_path, _expected), do: {:error, :missing_expected_head_commit}

  defp verify_fingerprint_matches(path, head, expected)
       when is_binary(expected) and expected != "" do
    case Workspace.worktree_fingerprint(path, head) do
      {:ok, ^expected} ->
        :ok

      {:ok, actual} ->
        {:error, {:workspace_fingerprint_drift, expected, actual}}

      {:error, reason} ->
        {:error, {:workspace_fingerprint_failed, reason}}
    end
  end

  defp verify_fingerprint_matches(_path, _head, _expected),
    do: {:error, :missing_expected_workspace_fingerprint}

  defp verify_tree_matches(path, expected) when is_binary(expected) and expected != "" do
    case MixAction.committable_tree_binding(path) do
      {:ok, %{tree_oid: ^expected}} ->
        :ok

      {:ok, %{tree_oid: actual}} ->
        {:error, {:validated_tree_drift, expected, actual}}

      {:error, reason} ->
        {:error, {:validated_tree_binding_failed, reason}}
    end
  end

  defp verify_tree_matches(_path, _expected), do: {:error, :missing_expected_tree_oid}

  defp verify_resulting_commit_tree(path, commit_hash, expected_tree)
       when is_binary(path) and is_binary(commit_hash) and commit_hash != "" and
              is_binary(expected_tree) and expected_tree != "" do
    case MixAction.commit_tree_oid(path, commit_hash) do
      {:ok, ^expected_tree} ->
        :ok

      {:ok, actual} ->
        {:error, {:resulting_tree_mismatch, expected_tree, actual}}

      {:error, reason} ->
        {:error, {:resulting_tree_lookup_failed, reason}}
    end
  end

  defp verify_resulting_commit_tree(_path, _commit_hash, _expected_tree),
    do: {:error, :missing_commit_hash}

  # Reject dirty worktrees whose HEAD has already advanced past the lease base.
  # That mixed mode is a self-commit plus residual dirt and cannot safely map to
  # either clean adoption or a dirty-from-base commit.
  defp reject_ambiguous_dirty_advanced_head(_path, false, _workspace_id, _context), do: :ok
  defp reject_ambiguous_dirty_advanced_head(_path, _dirty?, nil, _context), do: :ok

  defp reject_ambiguous_dirty_advanced_head(path, true, workspace_id, context)
       when is_binary(workspace_id) and workspace_id != "" do
    with {:ok, lease} <- resolve_workspace_lease(workspace_id, context),
         {:ok, base_commit} <- lease_base_commit(lease),
         {:ok, head} <- read_head(path) do
      if head == base_commit do
        :ok
      else
        {:error, {:ambiguous_dirty_advanced_head, base_commit, head}}
      end
    end
  end

  defp reject_ambiguous_dirty_advanced_head(_path, _dirty?, _workspace_id, _context),
    do: {:error, :invalid_workspace_binding}

  defp resolve_workspace_lease(workspace_id, context)
       when is_binary(workspace_id) and workspace_id != "" do
    caller = %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    }

    WorkspaceLeaseRegistry.inspect_lease(workspace_id, caller)
  end

  defp lease_base_commit(lease) when is_map(lease) do
    case Map.get(lease, :base_commit) || Map.get(lease, "base_commit") do
      base when is_binary(base) and base != "" -> {:ok, base}
      _ -> {:error, {:invalid_workspace_lease, :base_commit}}
    end
  end

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

  # -- linked-worktree storage authority -------------------------------------

  defp verify_workspace_binding(_path, nil, _context), do: :ok

  defp verify_workspace_binding(path, workspace_id, context) do
    case resolve_workspace_storage(workspace_id, path, context) do
      {:ok, _storage} -> :ok
      {:error, _} = error -> error
    end
  end

  defp with_workspace_storage_authority(nil, _path, _context, fun), do: fun.()

  defp with_workspace_storage_authority(workspace_id, path, context, fun)
       when is_function(fun, 0) do
    with {:ok, %{repo_path: repo_path, worktree_path: worktree_path}} <-
           resolve_workspace_storage(workspace_id, path, context) do
      Git.with_storage_authority(repo_path, worktree_path, fun)
    end
  end

  defp resolve_workspace_storage(workspace_id, path, context)
       when is_binary(workspace_id) and workspace_id != "" and is_binary(path) do
    caller = %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    }

    with {:ok, lease} <- WorkspaceLeaseRegistry.inspect_lease(workspace_id, caller),
         {:ok, repo_path} <- lease_path(lease, :repo_path),
         {:ok, worktree_path} <- lease_path(lease, :worktree_path),
         :ok <- require_same_canonical_path(path, worktree_path) do
      {:ok, %{repo_path: repo_path, worktree_path: worktree_path}}
    end
  end

  defp resolve_workspace_storage(_workspace_id, _path, _context),
    do: {:error, :invalid_workspace_binding}

  defp lease_path(lease, key) when is_map(lease) and is_atom(key) do
    case Map.get(lease, key) || Map.get(lease, Atom.to_string(key)) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, {:invalid_workspace_lease, key}}
    end
  end

  defp require_same_canonical_path(requested_path, leased_path) do
    with {:ok, requested} <- SafePath.resolve_real(requested_path),
         {:ok, leased} <- SafePath.resolve_real(leased_path) do
      if requested == leased, do: :ok, else: {:error, :workspace_path_mismatch}
    else
      _ -> {:error, :invalid_workspace_path}
    end
  end

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
    auth_context_signer =
      case Map.get(context, :auth_context) do
        %{signer: signer} when is_function(signer, 1) -> signer
        _ -> nil
      end

    direct_signer = Map.get(context, :signer)

    cond do
      is_function(auth_context_signer, 1) -> auth_context_signer
      not is_nil(direct_signer) -> direct_signer
      # The authority path exposes only this ephemeral signer, never its bearer.
      true -> nested_opt(context, :signer)
    end
  end

  defp nested_opt(context, key) do
    case Map.get(context, :nested_engine_opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  defp put_signed_request(context, signed_request) do
    context
    |> Map.put(:signed_request, signed_request)
    # Only a real proof envelope can participate in preverification. Untyped
    # legacy signer output is retained for ReviewedCommit's direct Trust call,
    # but must never be marked preverified or forwarded into generic action auth.
    |> Map.put(:identity_verified, false)
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

  defp maybe_drop_legacy_signed_request(context, signed_request)
       when is_map(context) and is_map(signed_request) do
    if not match?(%SignedRequest{}, signed_request) and
         not Arbor.Security.Config.identity_verification_enabled?() do
      context
      |> Map.delete(:signed_request)
      |> Map.delete("signed_request")
      |> clear_auth_context_signed_request()
    else
      context
    end
  end

  defp maybe_drop_legacy_signed_request(context, _signed_request), do: context

  defp clear_auth_context_signed_request(context) do
    case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
      %AuthContext{} = auth_context ->
        Map.put(context, :auth_context, %{auth_context | signed_request: nil})

      auth_context when is_map(auth_context) ->
        Map.put(
          context,
          :auth_context,
          auth_context
          |> Map.delete(:signed_request)
          |> Map.delete("signed_request")
        )

      _ ->
        context
    end
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

  defp git_commit_params(path, message, params, bindings) do
    %{
      path: path,
      message: message,
      all: truthy?(Map.get(params, :all, true)),
      allow_empty: truthy?(Map.get(params, :allow_empty, false)),
      expected_head_commit: bindings.head,
      expected_workspace_fingerprint: bindings.fingerprint,
      expected_tree_oid: bindings.tree_oid
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
  defp format_error(:invalid_expected_head_commit), do: "expected_head_commit is invalid"

  defp format_error(:missing_expected_workspace_fingerprint),
    do: "expected_workspace_fingerprint is required"

  defp format_error(:invalid_expected_workspace_fingerprint),
    do: "expected_workspace_fingerprint is invalid"

  defp format_error(:missing_expected_tree_oid), do: "expected_tree_oid is required"
  defp format_error(:invalid_expected_tree_oid), do: "expected_tree_oid is invalid"
  defp format_error(:missing_commit_hash), do: "commit hash missing after nested git commit"
  defp format_error(:missing_signing_authority), do: "signing authority required for git commit"
  defp format_error(:unauthorized), do: "unauthorized"

  defp format_error({:head_drift, expected, actual}),
    do: "head drifted during approval: expected=#{expected} actual=#{actual}"

  defp format_error({:workspace_fingerprint_drift, expected, actual}),
    do: "workspace fingerprint drifted during approval: expected=#{expected} actual=#{actual}"

  defp format_error({:workspace_fingerprint_failed, reason}),
    do: "workspace fingerprint verification failed: #{inspect(reason)}"

  defp format_error({:validated_tree_drift, expected, actual}),
    do: "validated tree drifted during approval: expected=#{expected} actual=#{actual}"

  defp format_error({:validated_tree_binding_failed, reason}),
    do: "validated tree binding failed: #{inspect(reason)}"

  defp format_error({:resulting_tree_mismatch, expected, actual}),
    do: "resulting commit tree mismatch: expected=#{expected} actual=#{actual}"

  defp format_error({:resulting_tree_lookup_failed, reason}),
    do: "resulting commit tree lookup failed: #{inspect(reason)}"

  defp format_error({:ambiguous_dirty_advanced_head, base, head}),
    do:
      "ambiguous dirty worktree with advanced HEAD: lease_base=#{base} head=#{head} " <>
        "(self-commit plus residual dirt is not a safe commit candidate)"

  defp format_error({:signing_failed, reason}), do: "signing failed: #{inspect(reason)}"

  defp format_error({:invalid_signing_authority, reason}),
    do: "invalid signing authority: #{inspect(reason)}"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
