defmodule Arbor.Security.Escalation do
  @moduledoc """
  Handles consensus escalation for capabilities with `requires_approval: true`.

  When a capability requires approval, this module submits a proposal to the
  configured consensus module and returns the proposal ID for async tracking.

  ## Configuration

  The consensus module is injected via config to avoid a hard dependency
  from `arbor_security` to `arbor_consensus`:

      config :arbor_security,
        consensus_module: Arbor.Consensus,      # default
        consensus_escalation_enabled: true       # default

  ## Proposal Format

  Submitted proposals include:

      %{
        proposer: principal_id,
        topic: :authorization_request,
        description: "Authorization request for resource",
        context: %{
          resource_uri: "arbor://...",
          action: "file.write",
          target: "/workspace/report.md",
          payload_preview: %{kind: :text, bytes: 1024, preview: "..."},
          provenance: %{session_id: "...", turn_id: "..."},
          gate: :requires_approval,
          reason: :capability_requires_approval,
          risk_hints: %{operation_taint: :untrusted}
        },
        metadata: %{
          principal_id: "agent_...",
          resource_uri: "arbor://...",
          capability_id: "cap_...",
          constraints: %{...},
          approval_context: %{...}
        }
      }
  """

  alias Arbor.Security.Config

  require Logger

  @preview_limit 500

  @sensitive_keys ~w(
    api_key
    authorization
    bearer
    client_secret
    cookie
    password
    private_key
    secret
    signed_request
    token
  )

  @payload_preview_keys ~w(
    body
    content
    data
    diff
    payload
    patch
    script
    stdin
  )a

  @doc """
  Check if the capability requires approval and submit for consensus if so.

  Returns:
  - `:ok` — no approval required, proceed with authorization
  - `{:ok, :pending_approval, proposal_id}` — submitted for consensus
  - `{:error, reason}` — consensus submission failed
  """
  @spec maybe_escalate(map(), String.t(), String.t(), keyword() | map()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, term()}
  def maybe_escalate(capability, principal_id, resource_uri, opts \\ []) do
    requires_approval? = approval_required?(capability)
    escalation_enabled? = Config.consensus_escalation_enabled?()
    consensus_module = Config.consensus_module()

    cond do
      not requires_approval? ->
        :ok

      # M2: Log when escalation is bypassed due to disabled config or missing module
      not escalation_enabled? ->
        Logger.warning("Escalation required but disabled: consensus_escalation_enabled is false",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        {:error, :escalation_disabled}

      is_nil(consensus_module) ->
        Logger.warning("Escalation required but no consensus_module configured",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        {:error, :no_consensus_module}

      not consensus_available?(consensus_module) ->
        # Consensus module configured but not available — fail closed
        {:error, :consensus_unavailable}

      true ->
        # Prefer the non-blocking InteractionRouter path when configured
        # AND the router is loadable at runtime. Fall back to the legacy
        # blocking consensus path otherwise.
        if Config.use_interaction_router_for_approval?() and interaction_router_available?() do
          submit_via_router(capability, principal_id, resource_uri, opts)
        else
          submit_for_approval(consensus_module, capability, principal_id, resource_uri, opts)
        end
    end
  end

  @doc """
  Submit an authorization request via `Arbor.Comms.InteractionRouter`.

  Non-blocking. Returns `{:ok, :pending_approval, request_id}`
  immediately. The agent's session/executor subscribes to
  `Arbor.Contracts.Comms.Interaction.response_topic_for_agent(principal_id)`
  and receives `{:interaction_response, %{...}}` when the human responds.

  Uses runtime bridges so `arbor_security` (Level 1) doesn't get a
  hierarchy-violating dep on `arbor_comms` (also Level 1).
  """
  @spec submit_via_router(map(), String.t(), String.t(), keyword() | map()) ::
          {:ok, :pending_approval, String.t()} | {:error, term()}
  def submit_via_router(capability, principal_id, resource_uri, opts \\ []) do
    router = Module.concat([:Arbor, :Comms, :InteractionRouter])
    interaction_mod = Module.concat([:Arbor, :Contracts, :Comms, :Interaction])

    if Code.ensure_loaded?(router) and Code.ensure_loaded?(interaction_mod) and
         function_exported?(router, :request, 2) do
      # Route to the human operator's user_id (the same identifier
      # Signal.PresenceKeeper registers with PresenceTracker). Without
      # this lookup, user_id == agent_id silently maps to a presence
      # nobody is registered for, the router queues with no adapter, and
      # the operator never sees the prompt.
      user_id = resolve_operator(principal_id)
      context = approval_context(capability, principal_id, resource_uri, opts)
      metadata = approval_metadata(capability, principal_id, resource_uri, context)

      attrs = %{
        kind: :approval,
        agent_id: principal_id,
        user_id: user_id,
        description: approval_description(resource_uri, context),
        resource_uri: resource_uri,
        metadata: metadata
      }

      case apply(router, :request, [attrs, []]) do
        {:ok, request_id} ->
          {:ok, :pending_approval, request_id}

        {:error, reason} = err ->
          Logger.warning(
            "Escalation: InteractionRouter.request failed for #{resource_uri}: #{inspect(reason)}"
          )

          err
      end
    else
      {:error, :interaction_router_unavailable}
    end
  rescue
    e ->
      Logger.warning("Escalation: submit_via_router crashed: #{Exception.message(e)}")
      {:error, {:interaction_router_crash, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("Escalation: submit_via_router exited: #{inspect(reason)}")
      {:error, {:interaction_router_exit, reason}}
  end

  # Cheap availability check used to gate the new path on each call.
  defp interaction_router_available? do
    router = Module.concat([:Arbor, :Comms, :InteractionRouter])
    Code.ensure_loaded?(router) and function_exported?(router, :request, 2)
  end

  # Resolve the human operator's user_id for routing. Uses
  # Arbor.Comms.operator_for_agent/1 when present (which reads the
  # configured operator from :arbor_comms, :signal, :interaction_user_id)
  # and falls back to principal_id for symmetry with the legacy
  # behavior in deployments without Arbor.Comms running.
  defp resolve_operator(principal_id) do
    comms = Module.concat([:Arbor, :Comms])

    if Code.ensure_loaded?(comms) and function_exported?(comms, :operator_for_agent, 1) do
      apply(comms, :operator_for_agent, [principal_id])
    else
      principal_id
    end
  end

  @doc """
  Submit an authorization request to the consensus system.
  """
  @spec submit_for_approval(module(), map(), String.t(), String.t(), keyword() | map()) ::
          {:ok, :pending_approval, String.t()} | {:error, term()}
  def submit_for_approval(consensus_module, capability, principal_id, resource_uri, opts \\ []) do
    context = approval_context(capability, principal_id, resource_uri, opts)
    metadata = approval_metadata(capability, principal_id, resource_uri, context)

    proposal = %{
      proposer: principal_id,
      topic: :authorization_request,
      description: approval_description(resource_uri, context),
      context: context,
      metadata: metadata
    }

    # Submit as human_approval — skips automated council evaluation.
    # The proposal stays :pending until force_approve/force_reject.
    # ActionsExecutor.await_approval_and_retry blocks until resolved.
    # Use a generous timeout — the Coordinator may be busy with other proposals.
    # The 5s default GenServer.call timeout is too short for a busy system.
    case consensus_module.submit(proposal, human_approval: true, timeout: 30_000) do
      {:ok, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, :duplicate_proposal} ->
        # A proposal for this resource is already pending — reuse it
        Logger.info("Escalation: reusing existing pending proposal for #{resource_uri}")
        {:ok, :pending_approval, "existing"}

      {:error, reason} ->
        {:error, {:consensus_submission_failed, reason}}
    end
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Escalation: consensus submit timed out for #{resource_uri}")
      {:error, {:consensus_timeout, resource_uri}}

    :exit, reason ->
      Logger.warning(
        "Escalation: consensus submit exited for #{resource_uri}: #{inspect(reason)}"
      )

      {:error, {:consensus_exit, reason}}
  end

  # Check if the consensus module is available (process running)
  defp consensus_available?(consensus_module) do
    # Try to check if the consensus system is healthy
    # Fall back to checking if the module is loaded
    if function_exported?(consensus_module, :healthy?, 0) do
      try do
        consensus_module.healthy?()
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    else
      Code.ensure_loaded?(consensus_module)
    end
  end

  defp approval_metadata(capability, principal_id, resource_uri, context) do
    %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      capability_id: capability.id,
      constraints: capability.constraints,
      approval_context: context,
      action: Map.get(context, :action),
      target: Map.get(context, :target),
      target_type: Map.get(context, :target_type),
      payload_preview: Map.get(context, :payload_preview),
      provenance: Map.get(context, :provenance),
      gate: Map.get(context, :gate),
      reason: Map.get(context, :reason),
      risk_hints: Map.get(context, :risk_hints)
    }
    |> compact_map()
  end

  defp approval_required?(capability) do
    constraints = capability.constraints || %{}

    constraints[:requires_approval] == true or
      constraints["requires_approval"] == true
  end

  defp approval_context(capability, principal_id, resource_uri, opts) do
    supplied =
      opts
      |> opt(:approval_context, %{})
      |> normalize_context_map()

    base =
      %{
        principal_id: principal_id,
        resource_uri: resource_uri,
        capability_id: capability.id,
        action: opt(opts, :approval_action),
        target: approval_target(resource_uri, opts),
        target_type: approval_target_type(opts),
        payload_preview: payload_preview(opts),
        params: sanitized_params(opt(opts, :params)),
        provenance: provenance(opts),
        gate: opt(opts, :gate, :requires_approval),
        reason: opt(opts, :reason, :capability_requires_approval),
        risk_hints: risk_hints(opts),
        constraints: capability.constraints
      }
      |> compact_map()

    deep_merge(base, supplied)
    |> Map.put_new(:principal_id, principal_id)
    |> Map.put_new(:resource_uri, resource_uri)
    |> Map.put_new(:capability_id, capability.id)
    |> Map.put_new(:gate, :requires_approval)
    |> Map.put_new(:reason, :capability_requires_approval)
  end

  defp approval_description(resource_uri, context) do
    case Map.get(context, :target) do
      nil -> "Authorization request for #{resource_uri}"
      target -> "Authorization request for #{resource_uri} -> #{target}"
    end
  end

  defp approval_target(resource_uri, opts) do
    cond do
      value = opt(opts, :target) ->
        preview_scalar(value)

      value = opt(opts, :file_path) ->
        preview_scalar(value)

      value = opt(opts, :command) ->
        preview_scalar(value)

      value = opt(opts, :egress_destination) ->
        preview_scalar(value)

      value = opt(opts, :path) ->
        preview_scalar(value)

      true ->
        resource_uri
    end
  end

  defp approval_target_type(opts) do
    cond do
      opt(opts, :target_type) -> opt(opts, :target_type)
      opt(opts, :file_path) -> :file_path
      opt(opts, :command) -> :command
      opt(opts, :egress_destination) -> :egress_destination
      opt(opts, :path) -> :path
      true -> :resource_uri
    end
  end

  defp payload_preview(opts) do
    case opt(opts, :payload_preview) do
      nil -> payload_preview_from_opts(opts)
      preview -> normalize_payload_preview(preview)
    end
  end

  defp payload_preview_from_opts(opts) do
    @payload_preview_keys
    |> Enum.find_value(fn key ->
      case opt(opts, key) do
        nil -> nil
        value -> preview_value(value, key)
      end
    end)
  end

  defp provenance(opts) do
    %{
      session_id: opt(opts, :session_id),
      turn_id: opt(opts, :turn_id),
      task_id: opt(opts, :task_id),
      node_id: opt(opts, :node_id),
      pipeline_id: opt(opts, :pipeline_id),
      engagement_id: opt(opts, :engagement_id),
      goal_id: opt(opts, :goal_id),
      trace_id: opt(opts, :trace_id)
    }
    |> compact_map()
  end

  defp risk_hints(opts) do
    %{
      workspace: opt(opts, :workspace),
      in_workspace:
        in_workspace?(opt(opts, :file_path) || opt(opts, :target), opt(opts, :workspace)),
      effect_class: opt(opts, :effect_class),
      operation_taint: opt(opts, :operation_taint),
      egress_taint: opt(opts, :egress_taint),
      egress_tier: opt(opts, :egress_tier),
      egress_destination: opt(opts, :egress_destination),
      external: external?(opts)
    }
    |> compact_map()
  end

  defp in_workspace?(path, workspace) when is_binary(path) and is_binary(workspace) do
    expanded_path = Path.expand(path)
    expanded_workspace = Path.expand(workspace)

    expanded_path == expanded_workspace or
      String.starts_with?(expanded_path, expanded_workspace <> "/")
  end

  defp in_workspace?(_path, _workspace), do: nil

  defp external?(opts) do
    cond do
      not is_nil(opt(opts, :egress_destination)) -> true
      opt(opts, :egress_tier) in [:external_provider, :external_peer] -> true
      true -> nil
    end
  end

  defp sanitized_params(nil), do: nil

  defp sanitized_params(params) when is_map(params) do
    params
    |> Enum.map(fn {key, value} -> {key, sanitize_param(key, value)} end)
    |> Map.new()
  end

  defp sanitized_params(_params), do: nil

  defp sanitize_param(key, value) do
    if sensitive_key?(key) do
      "[REDACTED]"
    else
      sanitize_value(value)
    end
  end

  defp sanitize_value(value) when is_binary(value), do: preview_scalar(value)

  defp sanitize_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: value

  defp sanitize_value(nil), do: nil

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.take(20)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.take(20)
    |> Enum.map(fn {key, nested_value} -> {key, sanitize_param(key, nested_value)} end)
    |> Map.new()
  end

  defp sanitize_value(value), do: inspect(value, limit: 20)

  defp normalize_context_map(context) when is_map(context) do
    context
    |> Enum.map(fn {key, value} -> {normalize_context_key(key), value} end)
    |> Map.new()
  end

  defp normalize_context_map(_context), do: %{}

  defp normalize_context_key(key) when is_atom(key), do: key

  defp normalize_context_key(key) when is_binary(key) do
    case key do
      "principal_id" -> :principal_id
      "resource_uri" -> :resource_uri
      "capability_id" -> :capability_id
      "action" -> :action
      "target" -> :target
      "target_type" -> :target_type
      "payload_preview" -> :payload_preview
      "params" -> :params
      "provenance" -> :provenance
      "gate" -> :gate
      "reason" -> :reason
      "risk_hints" -> :risk_hints
      "constraints" -> :constraints
      _ -> key
    end
  end

  defp normalize_context_key(key), do: key

  defp normalize_payload_preview(preview) when is_map(preview), do: preview
  defp normalize_payload_preview(preview), do: preview_value(preview, "payload")

  defp preview_value(value, kind) when is_binary(value) do
    %{
      kind: to_string(kind),
      bytes: byte_size(value),
      truncated: byte_size(value) > @preview_limit,
      preview: preview_scalar(value)
    }
  end

  defp preview_value(value, kind) do
    rendered = inspect(value, limit: 50)
    preview_value(rendered, kind)
  end

  defp preview_scalar(value) when is_binary(value) and byte_size(value) > @preview_limit do
    String.slice(value, 0, @preview_limit) <> "..."
  end

  defp preview_scalar(value) when is_binary(value), do: value
  defp preview_scalar(value), do: inspect(value, limit: 50)

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(fn key -> key in @sensitive_keys or String.ends_with?(key, "_token") end)
  end

  defp opt(opts, key, default \\ nil)

  defp opt(opts, key, default) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> get_list_option(opts, to_string(key), default)
    end
  end

  defp opt(opts, key, default) when is_map(opts) do
    cond do
      Map.has_key?(opts, key) -> Map.get(opts, key)
      Map.has_key?(opts, to_string(key)) -> Map.get(opts, to_string(key))
      true -> default
    end
  end

  defp opt(_opts, _key, default), do: default

  defp get_list_option(opts, key, default) do
    case List.keyfind(opts, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end
end
