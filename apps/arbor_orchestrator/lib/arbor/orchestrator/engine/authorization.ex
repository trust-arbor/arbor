defmodule Arbor.Orchestrator.Engine.Authorization do
  @moduledoc """
  Handler authorization layer for the DOT engine.

  Wraps handler execution with optional capability checks. Authorization is
  disabled by default for backward compatibility. When enabled, an injected
  authorizer function bridges to whatever security system the caller uses —
  no compile-time dependency on arbor_security.

  ## Options

    * `:authorization` - boolean, enables authorization checks (default: `false`)
    * `:authorizer` - function `(agent_id, handler_type) -> :ok | {:error, reason}`,
      required when authorization is enabled

  ## Examples

      # Authorization disabled (default) — passthrough to handler
      iex> alias Arbor.Orchestrator.Engine.{Authorization, Context, Outcome}
      iex> alias Arbor.Orchestrator.Graph.Node
      iex> handler = fn _node, _ctx, _graph, _opts -> %Outcome{status: :success, notes: "ran"} end
      iex> node = %Node{id: "build", attrs: %{"type" => "codergen"}}
      iex> ctx = Context.new()
      iex> outcome = Authorization.authorize_and_execute(handler, node, ctx, %{}, [])
      iex> outcome.status
      :success
      iex> outcome.notes
      "ran"

      # Authorization enabled, agent authorized
      iex> alias Arbor.Orchestrator.Engine.{Authorization, Context, Outcome}
      iex> alias Arbor.Orchestrator.Graph.Node
      iex> handler = fn _node, _ctx, _graph, _opts -> %Outcome{status: :success} end
      iex> authorizer = fn _agent_id, _type -> :ok end
      iex> node = %Node{id: "build", attrs: %{"type" => "codergen"}}
      iex> ctx = Context.new(%{"session.agent_id" => "agent_abc123"})
      iex> opts = [authorization: true, authorizer: authorizer]
      iex> outcome = Authorization.authorize_and_execute(handler, node, ctx, %{}, opts)
      iex> outcome.status
      :success

      # Authorization enabled, agent denied
      iex> alias Arbor.Orchestrator.Engine.{Authorization, Context, Outcome}
      iex> alias Arbor.Orchestrator.Graph.Node
      iex> handler = fn _n, _c, _g, _o -> %Outcome{status: :success} end
      iex> authorizer = fn _agent_id, _type -> {:error, "insufficient privileges"} end
      iex> node = %Node{id: "deploy", attrs: %{"type" => "tool"}}
      iex> ctx = Context.new(%{"session.agent_id" => "agent_untrusted"})
      iex> opts = [authorization: true, authorizer: authorizer]
      iex> outcome = Authorization.authorize_and_execute(handler, node, ctx, %{}, opts)
      iex> outcome.status
      :fail
      iex> outcome.failure_reason
      "unauthorized: tool for agent agent_untrusted"

      # Start/exit nodes have no required capability
      iex> Arbor.Orchestrator.Engine.Authorization.required_capability(%Arbor.Orchestrator.Graph.Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
      nil

      # Regular nodes require handler-type capability
      iex> Arbor.Orchestrator.Engine.Authorization.required_capability(%Arbor.Orchestrator.Graph.Node{id: "build", attrs: %{"type" => "codergen"}})
      "orchestrator:handler:codergen"

  """

  require Logger

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.Middleware.Chain
  alias Arbor.Orchestrator.Middleware.Token

  @always_authorized ~w(start exit)

  @doc """
  Authorize and execute a handler for the given node.

  When authorization is disabled (the default), the handler is called directly.
  When enabled, checks `opts[:authorizer]` before executing. Start and exit
  nodes are always authorized.

  The `handler` argument is either a module implementing the Handler behaviour
  (called as `handler.execute/4`) or a function with arity 4.
  """
  @spec authorize_and_execute(module() | function(), Node.t(), Context.t(), term(), keyword()) ::
          Outcome.t()
  def authorize_and_execute(handler, node, context, graph, opts) do
    if Keyword.get(opts, :authorization, false) do
      execute_with_authorization(handler, node, context, graph, opts)
    else
      call_handler(handler, node, context, graph, opts)
    end
  end

  @doc """
  Returns the capability URI required for a node's handler type.

  Format: `"orchestrator:handler:<type>"` where type is resolved via the
  handler registry. Returns `nil` for start/exit nodes (always authorized).
  """
  @spec required_capability(Node.t()) :: String.t() | nil
  def required_capability(%Node{} = node) do
    type = Registry.node_type(node)

    if type in @always_authorized do
      nil
    else
      "orchestrator:handler:#{type}"
    end
  end

  # --- Private ---

  defp execute_with_authorization(handler, node, context, graph, opts) do
    authority = Keyword.get(opts, :run_authorization)

    with %RunAuthorization{} <- authority,
         :ok <- RunAuthorization.verify_workdir(authority),
         :ok <- RunAuthorization.validate_node(node, authority),
         :ok <- RunAuthorization.verify_handler(authority, node, handler) do
      node = RunAuthorization.sanitize_node(node, authority)
      type = Registry.node_type(node)
      agent_id = authority.execution_principal

      if type in @always_authorized do
        Logger.debug("Authorization: #{type} node #{node.id} always authorized")
        call_handler(handler, node, context, graph, opts)
      else
        case check_authorization(opts, agent_id, type) do
          :ok ->
            Logger.debug(
              "Authorization: #{type} node #{node.id} authorized for agent #{agent_id}"
            )

            call_handler(handler, node, context, graph, opts)

          {:error, reason} ->
            Logger.debug(
              "Authorization: #{type} node #{node.id} denied for agent #{agent_id}: #{inspect(reason)}"
            )

            %Outcome{
              status: :fail,
              failure_reason: "unauthorized: #{type} for agent #{agent_id}"
            }
        end
      end
    else
      nil ->
        %Outcome{status: :fail, failure_reason: "unauthorized: missing run authorization"}

      {:error, {:graph_principal_override, node_id}} ->
        %Outcome{
          status: :fail,
          failure_reason: "unauthorized: graph principal override on node #{node_id}"
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "unauthorized: handler execution binding rejected: #{inspect(reason)}"
        }

      _ ->
        %Outcome{status: :fail, failure_reason: "unauthorized: invalid run authorization"}
    end
  end

  # Prefer the reload-stable SigningAuthority path. Never fall back to the
  # legacy authorizer/signer when an authority is present.
  defp check_authorization(opts, agent_id, type) when is_list(opts) do
    case Keyword.get(opts, :signing_authority) do
      %SigningAuthority{} = authority ->
        check_authority_authorization(authority, agent_id)

      nil ->
        check_legacy_authorization(Keyword.get(opts, :authorizer), agent_id, type)

      _invalid ->
        {:error, :invalid_signing_authority}
    end
  end

  defp check_authority_authorization(%SigningAuthority{} = authority, agent_id) do
    if authority.principal_id != agent_id do
      {:error, :principal_mismatch}
    else
      # Fixed named facade path — no injected security module.
      Arbor.Orchestrator.Authorization.check_orchestrator_access(agent_id, authority)
    end
  end

  defp check_legacy_authorization(nil, _agent_id, _type) do
    {:error, "no authorizer configured"}
  end

  defp check_legacy_authorization(authorizer, agent_id, type)
       when is_function(authorizer, 2) do
    authorizer.(agent_id, type)
  end

  defp check_legacy_authorization(_authorizer, _agent_id, _type) do
    {:error, "authorizer must be a function/2"}
  end

  defp call_handler(handler, node, context, graph, opts) do
    chain = Chain.build(opts, graph, node)

    if chain == [] do
      # No middleware — direct handler call (zero overhead)
      do_call_handler(handler, node, context, graph, opts)
    else
      execute_with_middleware(handler, node, context, graph, opts, chain)
    end
  end

  defp execute_with_middleware(handler, node, context, graph, opts, chain) do
    token = %Token{
      node: node,
      context: context,
      graph: graph,
      logs_root: Keyword.get(opts, :logs_root, ""),
      assigns: build_assigns(context, opts, node)
    }

    # Run before_node middleware
    token = Chain.run_before(chain, token)

    if token.halted do
      # Middleware halted — return the outcome (Chain.run_before ensures one exists)
      token.outcome || %Outcome{status: :fail, failure_reason: token.halt_reason}
    else
      # Execute the actual handler
      outcome = do_call_handler(handler, node, context, graph, opts)

      # Run after_node middleware with the outcome
      token = %{token | outcome: outcome}
      token = Chain.run_after(chain, token)

      token.outcome || outcome
    end
  end

  defp do_call_handler(handler, node, context, graph, opts) when is_function(handler, 4) do
    handler.(node, context, graph, opts)
  end

  defp do_call_handler(handler, node, context, graph, opts) when is_atom(handler) do
    alias Arbor.Orchestrator.Handlers.BehaviourHelpers

    if Arbor.Orchestrator.Handlers.Handler.three_phase?(handler) do
      BehaviourHelpers.execute_three_phase(handler, node, context, graph, opts)
    else
      BehaviourHelpers.execute(handler, node, context, graph, opts)
    end
  end

  defp build_assigns(context, opts, node) do
    authority = Keyword.get(opts, :run_authorization)

    assigns = %{
      authorization: Keyword.get(opts, :authorization, false),
      run_authorization: authority
    }

    assigns =
      case authority do
        %RunAuthorization{} = auth ->
          assigns
          |> Map.put(:agent_id, auth.execution_principal)
          |> Map.put(:caller_id, auth.caller_id)
          |> Map.put(:author_id, auth.author_id)
          |> Map.put(:task_id, auth.task_id)
          |> Map.put(:session_id, auth.session_id)
          |> Map.put(:workdir, auth.workdir)

        _ ->
          case Context.get(context, "session.agent_id") do
            nil -> assigns
            agent_id -> Map.put(assigns, :agent_id, agent_id)
          end
      end

    # Process-local only: opaque SigningAuthority for CapabilityCheck.
    # Never put into Engine context / checkpoint / RunAuthorization.
    # Invalid non-nil authority is still attached so CapabilityCheck fails closed
    # and never falls through to the legacy signer path.
    assigns =
      case Keyword.get(opts, :signing_authority) do
        %SigningAuthority{} = signing_authority ->
          Map.put(assigns, :signing_authority, signing_authority)

        nil ->
          assigns

        invalid ->
          Map.put(assigns, :signing_authority, invalid)
      end

    # Legacy: thread signer function for signed request creation in CapabilityCheck.
    # When an authority is present (valid or invalid non-nil), do not attach the
    # legacy signer (exclusivity — never fall through).
    assigns =
      if Map.has_key?(assigns, :signing_authority) do
        assigns
      else
        case Keyword.get(opts, :signer) do
          signer when is_function(signer, 1) -> Map.put(assigns, :signer, signer)
          _ -> assigns
        end
      end

    node_type = Registry.node_type(node)

    if Keyword.get(opts, :authorization) == false or node_type in @always_authorized do
      Map.put(assigns, :skip_capability_check, true)
    else
      assigns
    end
  end
end
