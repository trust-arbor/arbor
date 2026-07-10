defmodule Arbor.Orchestrator.Middleware.CapabilityCheck do
  @moduledoc """
  Mandatory middleware that checks capability authorization before node execution.

  Bridges to `Arbor.Security.authorize/4` when available. Halts execution if the
  agent lacks the required capability for the node's operation.

  When a compiled node has `capabilities_required` populated by the IR Compiler,
  ALL listed capabilities are checked. Falls back to a single type-based URI
  for uncompiled graphs.

  When the security subsystem is unavailable, behavior follows
  `Arbor.Orchestrator.Config.security_required?()` (fail-closed by default).

  ## Token Assigns

    - `:agent_id` — the agent ID to check capabilities for (defaults to `"agent_system"`)
    - `:skip_capability_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.Registry

  @impl true
  def before_node(token) do
    cond do
      Map.get(token.assigns, :skip_capability_check, false) ->
        token

      Map.get(token.assigns, :authorization) == false ->
        token

      not match?(%RunAuthorization{}, Map.get(token.assigns, :run_authorization)) ->
        halt(token, "Missing immutable run authorization")

      not Arbor.Orchestrator.Config.security_available?() ->
        halt(token, "Security subsystem unavailable (fail-closed)")

      true ->
        check_capabilities(token)
    end
  end

  @orchestrator_uri_prefix "arbor://orchestrator/execute/"

  @doc """
  Returns the list of capability URIs required for a node.

  Uses `node.capabilities_required` if populated by IR Compiler,
  otherwise falls back to a single URI derived from the node type.

  Bare capability names (e.g. `"llm_query"`) are normalized to full
  URIs (`"arbor://orchestrator/execute/llm_query"`) so they can be
  matched against wildcard grants like `"arbor://orchestrator/execute/**"`.
  """
  @spec capability_resources(Arbor.Orchestrator.Graph.Node.t()) :: [String.t()]
  def capability_resources(node) do
    # Read defensively: a fully-built %Graph.Node{} always carries
    # `capabilities_required` (defaults to []), but uncompiled / partially
    # constructed nodes may omit the key entirely. Absence means "no caps
    # populated by the IR Compiler" — fall back to the type-based URI rather
    # than crashing with a KeyError.
    declared =
      case Map.get(node, :capabilities_required, []) do
        caps when is_list(caps) -> Enum.flat_map(caps, &normalize_capability_uri(&1, node))
        _ -> []
      end

    resources = Enum.uniq(declared ++ derived_effect_resources(node))

    if resources == [] do
      [@orchestrator_uri_prefix <> Map.get(node.attrs, "type", "unknown")]
    else
      resources
    end
  end

  defp normalize_capability_uri(cap, node)
       when cap in ["file_read", "arbor://orchestrator/execute/file_read"],
       do: [file_read_resource(node)]

  defp normalize_capability_uri(cap, node)
       when cap in ["file_write", "arbor://orchestrator/execute/file_write"],
       do: [file_write_resource(node)]

  defp normalize_capability_uri(cap, node)
       when cap in ["shell_exec", "arbor://orchestrator/execute/shell_exec"],
       do: [shell_or_exec_resource(node)]

  defp normalize_capability_uri("arbor://pipeline/run", _node),
    do: ["arbor://action/pipeline/run"]

  defp normalize_capability_uri(cap, _node) when is_binary(cap) do
    if String.starts_with?(cap, "arbor://") do
      [cap]
    else
      [@orchestrator_uri_prefix <> cap]
    end
  end

  defp check_capabilities(token) do
    case Map.get(token.assigns, :agent_id) do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        check_all_resources(token, agent_id, capability_resources(token.node))

      _ ->
        halt(token, "Missing execution principal (fail-closed)")
    end
  end

  defp check_all_resources(token, _agent_id, []), do: token

  defp check_all_resources(token, agent_id, [resource | rest]) do
    with {:ok, auth_opts} <- build_auth_opts(token, resource),
         :ok <- authorize_caller(token, resource, auth_opts) do
      case Arbor.Orchestrator.Config.security_module().authorize(
             agent_id,
             resource,
             :execute,
             auth_opts
           ) do
        {:ok, :authorized} ->
          check_all_resources(token, agent_id, rest)

        # Explicit-path (FileGuard) authorizations can return a 3-tuple carrying
        # the resolved path; a granted authorization still proceeds.
        {:ok, :authorized, _resolved_path} ->
          check_all_resources(token, agent_id, rest)

        {:ok, :pending_approval, proposal_id} ->
          halt(
            token,
            "Capability check pending approval: #{resource} " <>
              "(proposal #{inspect(proposal_id)})"
          )

        {:error, reason} ->
          halt(token, "Capability check failed: #{resource} (#{inspect(reason)})")

        other ->
          halt(token, "Capability check returned unexpected result: #{inspect(other)}")
      end
    else
      {:error, reason} -> halt(token, format_authorization_error(resource, reason))
    end
  rescue
    error ->
      Token.halt(
        token,
        "capability check error for #{resource}",
        %Outcome{
          status: :fail,
          failure_reason: "Capability check error (#{inspect(error)}) — failing closed"
        }
      )
  catch
    :exit, reason ->
      Token.halt(
        token,
        "capability check exit for #{resource}",
        %Outcome{
          status: :fail,
          failure_reason: "Capability check exit (#{inspect(reason)}) — failing closed"
        }
      )
  end

  defp build_auth_opts(token, resource) do
    authority = Map.fetch!(token.assigns, :run_authorization)

    base =
      RunAuthorization.scope_opts(authority)
      |> Keyword.put(:workdir, authority.workdir)

    with {:ok, path_opts} <- path_auth_opts(token.node, resource, authority.workdir),
         {:ok, signer_opts} <- signer_auth_opts(token.assigns, resource) do
      {:ok, base ++ path_opts ++ signer_opts}
    end
  end

  defp signer_auth_opts(assigns, resource) do
    case Map.get(assigns, :signer) do
      signer when is_function(signer, 1) ->
        case signer.(resource) do
          {:ok, signed_request} -> {:ok, [signed_request: signed_request]}
          {:error, reason} -> {:error, {:signing_failed, reason}}
          other -> {:error, {:invalid_signer_result, other}}
        end

      _ ->
        {:ok, []}
    end
  end

  defp authorize_caller(token, resource, auth_opts) do
    authority = Map.fetch!(token.assigns, :run_authorization)

    if authority.caller_id == authority.execution_principal do
      :ok
    else
      security = Arbor.Orchestrator.Config.security_module()

      with true <- function_exported?(security, :list_capabilities, 2),
           true <- function_exported?(security, :capability_authorizes?, 3),
           {:ok, effective_resource} <- effective_resource(security, resource, auth_opts),
           {:ok, capabilities} <-
             security.list_capabilities(
               authority.caller_id,
               RunAuthorization.scope_opts(authority)
             ),
           true <-
             Enum.any?(capabilities, fn capability ->
               security.capability_authorizes?(
                 capability,
                 effective_resource,
                 RunAuthorization.scope_opts(authority)
               )
             end) do
        :ok
      else
        _ -> {:error, {:caller_authority_missing, authority.caller_id}}
      end
    end
  end

  defp effective_resource(security, resource, auth_opts) do
    cond do
      function_exported?(security, :normalize_authorization_resource_uri, 2) ->
        security.normalize_authorization_resource_uri(resource, auth_opts)

      function_exported?(security, :authorization_resource_uri, 2) ->
        {:ok, security.authorization_resource_uri(resource, auth_opts)}

      true ->
        {:ok, resource}
    end
  end

  defp path_auth_opts(_node, resource, _workdir)
       when resource not in ["arbor://fs/read", "arbor://fs/write"],
       do: {:ok, []}

  defp path_auth_opts(node, _resource, workdir) do
    case file_path(node) do
      nil ->
        {:ok, []}

      path when is_binary(path) ->
        case SafePath.resolve_within(path, workdir) do
          {:ok, resolved} -> {:ok, [file_path: resolved]}
          {:error, reason} -> {:error, {:invalid_file_path, path, reason}}
        end

      path ->
        {:error, {:invalid_file_path, path}}
    end
  end

  defp file_path(node) do
    attrs = node.attrs
    type = Registry.node_type(node)

    cond do
      type in ["file.write", "write"] ->
        Map.get(attrs, "output") || Map.get(attrs, "path")

      type == "read" ->
        Map.get(attrs, "path") || Map.get(attrs, "source_key")

      type == "eval.dataset" ->
        Map.get(attrs, "dataset")

      type in ["graph.invoke", "compose"] ->
        Map.get(attrs, "graph_file") || Map.get(attrs, "file")

      type == "pipeline.run" ->
        Map.get(attrs, "source_file") || Map.get(attrs, "file")

      type == "exec" and Map.get(attrs, "target") == "action" ->
        Map.get(attrs, "param.path") || Map.get(attrs, "arg.path") ||
          Map.get(attrs, "param.file_path") || Map.get(attrs, "arg.file_path") ||
          Map.get(attrs, "param.base_path") || Map.get(attrs, "arg.base_path")

      true ->
        nil
    end
  end

  defp derived_effect_resources(node) do
    type = Registry.node_type(node)
    attrs = node.attrs

    cond do
      type == "read" and Map.get(attrs, "source", "file") != "context" ->
        ["arbor://fs/read"]

      type in ["file.write", "write"] and Map.get(attrs, "target", "file") != "accumulator" ->
        ["arbor://fs/write"]

      type in ["tool", "shell"] ->
        ["arbor://shell/exec"]

      type == "exec" ->
        [shell_or_exec_resource(node)]

      type in ["graph.invoke", "compose"] and
          present?(Map.get(attrs, "graph_file") || Map.get(attrs, "file")) ->
        ["arbor://fs/read"]

      type == "pipeline.run" and
          present?(Map.get(attrs, "source_file") || Map.get(attrs, "file")) ->
        ["arbor://action/pipeline/run", "arbor://fs/read"]

      true ->
        []
    end
  end

  defp file_read_resource(node) do
    if Registry.node_type(node) == "read" and Map.get(node.attrs, "source") == "context" do
      @orchestrator_uri_prefix <> "read"
    else
      "arbor://fs/read"
    end
  end

  defp file_write_resource(node) do
    if Registry.node_type(node) == "write" and
         Map.get(node.attrs, "target") == "accumulator" do
      @orchestrator_uri_prefix <> "write"
    else
      "arbor://fs/write"
    end
  end

  defp shell_or_exec_resource(node) do
    if Registry.node_type(node) == "exec" and Map.get(node.attrs, "target") == "action" do
      action_resource(Map.get(node.attrs, "action"))
    else
      "arbor://shell/exec"
    end
  end

  defp action_resource(action) when is_binary(action) and action != "" do
    case Arbor.Actions.tool_name_to_canonical_uri(action) do
      {:ok, resource} -> resource
      :error -> @orchestrator_uri_prefix <> "exec"
    end
  end

  defp action_resource(_action), do: @orchestrator_uri_prefix <> "exec"

  defp format_authorization_error(resource, {:caller_authority_missing, caller_id}) do
    "Caller authority check failed: #{resource} for #{caller_id}"
  end

  defp format_authorization_error(resource, reason) do
    "Capability check failed: #{resource} (#{inspect(reason)})"
  end

  defp halt(token, message) do
    Token.halt(token, message, %Outcome{status: :fail, failure_reason: message})
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
