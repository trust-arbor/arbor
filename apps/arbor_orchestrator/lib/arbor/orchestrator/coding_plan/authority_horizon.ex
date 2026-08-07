defmodule Arbor.Orchestrator.CodingPlan.AuthorityHorizon do
  @moduledoc """
  Fail-closed coding-run authority-horizon preflight shell.

  Derives the complete required resource set from the verified compiled
  top-level graph, hash-verified reviewed nested graphs, and execution
  manifest transitive action capability URIs. Proves each required principal
  holds authorizing capabilities valid through the immutable run horizon.

  Uses only public Security facades for enumeration. Does not grant, renew,
  extend, or replace runtime per-node reauthorization.
  """

  alias Arbor.Contracts.Coding.Diagnostic
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Orchestrator.CodingPlan.{AuthorityHorizonCore, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler
  alias Arbor.Orchestrator.Middleware.CapabilityCheck
  alias Arbor.Orchestrator.Viz.DotSerializer

  @type preflight_opts :: keyword()

  @stable_reason_messages %{
    invalid_authority_horizon_opts: "authority horizon preflight rejected invalid inputs",
    invalid_resource_derivation_input: "authority horizon could not derive required resources",
    invalid_horizon: "authority horizon deadline inputs were invalid",
    invalid_horizon_datetime: "authority horizon deadline could not be converted",
    nested_graph_cycle: "authority horizon detected a nested graph cycle",
    nested_graph_authority_drift: "authority horizon nested graph hashes drifted",
    nested_graph_load_failed: "authority horizon could not load a nested reviewed graph",
    nested_graph_source_unavailable: "authority horizon nested graph source was unavailable",
    nested_graph_parse_failed: "authority horizon nested graph parse failed",
    nested_graph_hash_failed: "authority horizon nested graph hash failed",
    unknown_nested_graph: "authority horizon referenced an unknown nested graph",
    invalid_nested_graph_entry: "authority horizon nested graph entry was invalid",
    list_capabilities_unavailable: "authority horizon security enumeration was unavailable",
    list_capabilities_failed: "authority horizon security enumeration failed",
    authority_horizon_exception: "authority horizon preflight failed closed",
    authority_horizon_throw: "authority horizon preflight failed closed",
    authority_horizon_diagnostic_invalid: "authority horizon diagnostic projection failed"
  }

  @doc """
  Run the authority-horizon preflight.

  On failure returns `{:error, {:authority_horizon_diagnostic, diagnostic_map}}`
  suitable for `CodingTaskExecutor.coding_admission_error/1`.
  """
  @spec preflight(preflight_opts()) ::
          :ok | {:error, {:authority_horizon_diagnostic, map()} | term()}
  def preflight(opts) when is_list(opts) do
    with {:ok, ctx} <- validate_opts(opts),
         {:ok, horizon_unix_ms} <-
           AuthorityHorizonCore.horizon_unix_ms(
             ctx.run_deadline_unix_ms,
             ctx.cleanup_reserve_ms
           ),
         {:ok, horizon_dt} <- horizon_datetime(horizon_unix_ms),
         {:ok, resources} <-
           derive_required_resources(ctx.compiled_graph, ctx.execution_manifest) do
      principals =
        AuthorityHorizonCore.principals(ctx.execution_principal, ctx.caller_id)

      results =
        Enum.flat_map(principals, fn {role, principal_id} ->
          classify_principal_resources(
            ctx.security,
            principal_id,
            role,
            resources,
            ctx.scope_opts,
            horizon_dt
          )
        end)

      case AuthorityHorizonCore.aggregate_findings(results) do
        :ok ->
          :ok

        {:error, findings} ->
          observed_at = DateTime.to_iso8601(ctx.now, :extended)
          payload = AuthorityHorizonCore.project_diagnostic_payload(findings, observed_at)
          diagnostic_error(payload, observed_at)
      end
    else
      {:error, {:authority_horizon_diagnostic, _}} = error ->
        error

      {:error, reason} ->
        missing_diagnostic(reason, opts)
    end
  rescue
    _exception ->
      missing_diagnostic(:authority_horizon_exception, opts)
  catch
    _kind, _reason ->
      missing_diagnostic(:authority_horizon_throw, opts)
  end

  def preflight(_opts), do: missing_diagnostic(:invalid_authority_horizon_opts, [])

  @doc """
  Derive the complete required resource URI set for a coding run.
  """
  @spec derive_required_resources(Graph.t(), map()) ::
          {:ok, [String.t()]} | {:error, term()}
  def derive_required_resources(%Graph{} = compiled_graph, execution_manifest)
      when is_map(execution_manifest) do
    with {:ok, nested_graphs} <- load_verified_nested_graphs(execution_manifest, MapSet.new()) do
      top_node_resources = node_resources(compiled_graph)

      nested_node_resources =
        Enum.flat_map(nested_graphs, fn {_id, graph} -> node_resources(graph) end)

      manifest_uris = collect_manifest_capability_uris(execution_manifest)

      resources =
        AuthorityHorizonCore.union_resources([
          top_node_resources,
          nested_node_resources,
          manifest_uris
        ])

      {:ok, resources}
    end
  end

  def derive_required_resources(_compiled_graph, _execution_manifest),
    do: {:error, :invalid_resource_derivation_input}

  defp validate_opts(opts) do
    security = Keyword.get(opts, :security)
    execution_principal = Keyword.get(opts, :execution_principal)
    compiled_graph = Keyword.get(opts, :compiled_graph)
    execution_manifest = Keyword.get(opts, :execution_manifest)
    run_deadline = Keyword.get(opts, :run_deadline_unix_ms)
    cleanup_reserve = Keyword.get(opts, :cleanup_reserve_ms)
    task_id = Keyword.get(opts, :task_id)
    session_id = Keyword.get(opts, :session_id)
    caller_id = Keyword.get(opts, :caller_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with true <- is_atom(security) and not is_nil(security),
         true <- is_binary(execution_principal) and execution_principal != "",
         true <- match?(%Graph{}, compiled_graph),
         true <- is_map(execution_manifest),
         true <- is_integer(run_deadline) and run_deadline > 0,
         true <- is_integer(cleanup_reserve) and cleanup_reserve >= 0,
         true <- is_binary(task_id) and task_id != "",
         true <- match?(%DateTime{}, now) do
      scope_opts =
        [task_id: task_id]
        |> maybe_put_scope(:session_id, session_id)

      {:ok,
       %{
         security: security,
         execution_principal: execution_principal,
         caller_id: caller_id,
         compiled_graph: compiled_graph,
         execution_manifest: execution_manifest,
         run_deadline_unix_ms: run_deadline,
         cleanup_reserve_ms: cleanup_reserve,
         scope_opts: scope_opts,
         now: now
       }}
    else
      _ -> {:error, :invalid_authority_horizon_opts}
    end
  end

  defp maybe_put_scope(opts, _key, value) when value in [nil, ""], do: opts

  defp maybe_put_scope(opts, key, value) when is_binary(value),
    do: Keyword.put(opts, key, value)

  defp maybe_put_scope(opts, _key, _value), do: opts

  defp horizon_datetime(horizon_unix_ms) when is_integer(horizon_unix_ms) do
    case DateTime.from_unix(horizon_unix_ms, :millisecond) do
      {:ok, dt} -> {:ok, dt}
      {:error, _reason} -> {:error, :invalid_horizon_datetime}
    end
  end

  defp node_resources(%Graph{nodes: nodes}) when is_map(nodes) do
    nodes
    |> Map.values()
    |> Enum.reject(&sentinel_node?/1)
    |> Enum.flat_map(&CapabilityCheck.capability_resources/1)
  end

  defp node_resources(_graph), do: []

  # Entry/exit sentinels (`start [shape=Mdiamond]`, `done [shape=Msquare]`)
  # carry no `type` attribute because they execute nothing.
  #
  # CapabilityCheck.capability_resources/1 falls back to
  # "arbor://orchestrator/execute/" <> Map.get(attrs, "type", "unknown"). At
  # RUNTIME that default is deliberate fail-closed behaviour: a node whose type
  # is unrecognised demands a capability nobody holds, so it cannot execute.
  # That behaviour is intentionally left alone.
  #
  # Preflight is different. It unions resources over EVERY node to derive what
  # the caller must hold up front, so the sentinels contributed a literal
  # `arbor://orchestrator/execute/unknown` to the required set. That is a parse
  # placeholder, not a permission: no operator would think to grant it, and
  # granting it would be meaningless. It made every coding dispatch fail
  # admission with `authority_horizon_missing` until the caller held a
  # nonsense capability. Sentinels are excluded here, not in the runtime gate.
  defp sentinel_node?(node) do
    attrs = Map.get(node, :attrs, %{})

    is_nil(Map.get(attrs, "type")) and
      Map.get(attrs, "shape") in ["Mdiamond", "Msquare"]
  end

  defp collect_manifest_capability_uris(manifest) when is_map(manifest) do
    direct =
      case Map.get(manifest, "capability_uris") do
        uris when is_list(uris) -> uris
        _ -> []
      end

    nested =
      case Map.get(manifest, "nested_graphs") do
        graphs when is_list(graphs) ->
          Enum.flat_map(graphs, fn
            %{"execution_manifest" => child} when is_map(child) ->
              collect_manifest_capability_uris(child)

            _ ->
              []
          end)

        _ ->
          []
      end

    direct ++ nested
  end

  defp collect_manifest_capability_uris(_manifest), do: []

  defp load_verified_nested_graphs(manifest, visited) when is_map(manifest) do
    case Map.get(manifest, "nested_graphs") do
      graphs when is_list(graphs) and graphs != [] ->
        Enum.reduce_while(graphs, {:ok, []}, fn entry, {:ok, acc} ->
          case load_verified_nested_entry(entry, visited) do
            {:ok, pairs} -> {:cont, {:ok, acc ++ pairs}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _ ->
        {:ok, []}
    end
  end

  defp load_verified_nested_graphs(_manifest, _visited), do: {:ok, []}

  defp load_verified_nested_entry(%{"id" => id} = entry, visited)
       when is_binary(id) and id != "" do
    if MapSet.member?(visited, id) do
      {:error, :nested_graph_cycle}
    else
      with {:ok, source} <- nested_source(id),
           {:ok, graph} <- parse_graph(source),
           {:ok, compiled} <- IRCompiler.compile(graph),
           {:ok, graph_hash} <- nested_graph_hash(compiled),
           :ok <- require_equal_hash(entry, "graph_hash", graph_hash),
           {:ok, compiled_hash} <- ExecutionManifest.compiled_graph_hash(compiled),
           :ok <- require_equal_hash(entry, "compiled_graph_hash", compiled_hash),
           child_manifest = Map.get(entry, "execution_manifest") || %{},
           {:ok, deeper} <-
             load_verified_nested_graphs(child_manifest, MapSet.put(visited, id)) do
        {:ok, [{id, compiled} | deeper]}
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, {reason, _}} when is_atom(reason) -> {:error, reason}
        {:error, _} -> {:error, :nested_graph_load_failed}
        _ -> {:error, :nested_graph_load_failed}
      end
    end
  end

  defp load_verified_nested_entry(_entry, _visited),
    do: {:error, :invalid_nested_graph_entry}

  defp nested_source(id) do
    case Arbor.Actions.reviewed_pipeline(id) do
      {:ok, reviewed} ->
        source =
          cond do
            is_map(reviewed) and is_binary(Map.get(reviewed, :source)) ->
              Map.get(reviewed, :source)

            is_map(reviewed) and is_binary(Map.get(reviewed, "source")) ->
              Map.get(reviewed, "source")

            true ->
              nil
          end

        if is_binary(source) and source != "" do
          {:ok, source}
        else
          {:error, :nested_graph_source_unavailable}
        end

      {:error, {:unknown_reviewed_pipeline, ^id}} ->
        {:error, :unknown_nested_graph}

      {:error, _reason} ->
        {:error, :nested_graph_source_unavailable}
    end
  rescue
    _ -> {:error, :nested_graph_source_unavailable}
  catch
    _, _ -> {:error, :nested_graph_source_unavailable}
  end

  defp parse_graph(source) do
    case Parser.parse(source) do
      {:ok, graph} -> {:ok, graph}
      {:ok, graph, _errors} -> {:ok, graph}
      {:error, _reason} -> {:error, :nested_graph_parse_failed}
    end
  end

  defp nested_graph_hash(%Graph{} = graph) do
    {:ok, graph |> DotSerializer.serialize() |> sha256()}
  rescue
    _ -> {:error, :nested_graph_hash_failed}
  end

  defp require_equal_hash(entry, key, actual) when is_binary(actual) do
    case Map.get(entry, key) do
      ^actual -> :ok
      _ -> {:error, :nested_graph_authority_drift}
    end
  end

  defp require_equal_hash(_entry, _key, _actual),
    do: {:error, :nested_graph_authority_drift}

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp classify_principal_resources(
         security,
         principal_id,
         role,
         resources,
         scope_opts,
         horizon_dt
       ) do
    case list_capabilities(security, principal_id, scope_opts) do
      {:ok, capabilities} when is_list(capabilities) ->
        Enum.map(resources, fn resource ->
          authorizing = authorizing_caps(security, capabilities, resource, scope_opts)

          classification =
            AuthorityHorizonCore.classify_resource_coverage(authorizing, horizon_dt)

          {role, resource, classification}
        end)

      _error ->
        Enum.map(resources, fn resource -> {role, resource, :missing} end)
    end
  end

  defp list_capabilities(security, principal_id, scope_opts) do
    _ = Code.ensure_loaded(security)

    if function_exported?(security, :list_capabilities, 2) do
      security.list_capabilities(principal_id, scope_opts)
    else
      {:error, :list_capabilities_unavailable}
    end
  rescue
    _ -> {:error, :list_capabilities_failed}
  catch
    _, _ -> {:error, :list_capabilities_failed}
  end

  defp authorizing_caps(security, capabilities, resource, scope_opts) do
    effective =
      case effective_resource(security, resource, scope_opts) do
        {:ok, uri} -> uri
        _ -> resource
      end

    Enum.filter(capabilities, fn capability ->
      capability_authorizes?(security, capability, effective, scope_opts)
    end)
  end

  defp capability_authorizes?(security, capability, resource, scope_opts) do
    _ = Code.ensure_loaded(security)

    cond do
      function_exported?(security, :capability_authorizes?, 3) ->
        security.capability_authorizes?(capability, resource, scope_opts) == true

      match?(%Capability{}, capability) ->
        Capability.valid?(capability) and Capability.scope_matches?(capability, scope_opts) and
          Capability.grants_access?(capability, resource)

      true ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp effective_resource(security, resource, auth_opts) do
    _ = Code.ensure_loaded(security)

    cond do
      function_exported?(security, :normalize_authorization_resource_uri, 2) ->
        security.normalize_authorization_resource_uri(resource, auth_opts)

      function_exported?(security, :authorization_resource_uri, 2) ->
        {:ok, security.authorization_resource_uri(resource, auth_opts)}

      true ->
        {:ok, resource}
    end
  rescue
    _ -> {:ok, resource}
  catch
    _, _ -> {:ok, resource}
  end

  defp diagnostic_error(payload, observed_at) when is_map(payload) do
    case Diagnostic.normalize(Map.drop(payload, [:findings, "findings"])) do
      {:ok, diagnostic} ->
        {:error, {:authority_horizon_diagnostic, diagnostic}}

      {:error, _reason} ->
        minimal = %{
          "version" => Diagnostic.schema_version(),
          "gate_id" => "authority_horizon",
          "phase" => "preflight",
          "decision" => "blocked",
          "code" =>
            Map.get(payload, :code) || Map.get(payload, "code") || "authority_horizon_missing",
          "observed_at" => observed_at,
          "message" =>
            AuthorityHorizonCore.bound_text(
              Map.get(payload, :message) || Map.get(payload, "message") ||
                "authority horizon preflight failed",
              256
            ),
          "remediation" =>
            Map.get(payload, :remediation) || Map.get(payload, "remediation") ||
              "Grant permanent or horizon-covering capabilities for required resources."
        }

        case Diagnostic.normalize(minimal) do
          {:ok, diagnostic} ->
            {:error, {:authority_horizon_diagnostic, diagnostic}}

          {:error, _reason} ->
            {:error, :authority_horizon_diagnostic_invalid}
        end
    end
  end

  defp missing_diagnostic(reason, opts) do
    observed_at =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> DateTime.to_iso8601(now, :extended)
        _ -> DateTime.utc_now() |> DateTime.to_iso8601(:extended)
      end

    reason_class = stable_reason_class(reason)

    findings = [
      %{
        role: :execution_principal,
        classification: :missing,
        resource_uris: [],
        total_count: 0
      }
    ]

    payload =
      findings
      |> AuthorityHorizonCore.project_diagnostic_payload(observed_at)
      |> Map.put(:message, stable_reason_message(reason_class))
      |> Map.put(
        :evidence_ref,
        AuthorityHorizonCore.bound_text("reason_class=#{reason_class}", 256)
      )

    diagnostic_error(payload, observed_at)
  end

  defp stable_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp stable_reason_class({reason, _detail}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp stable_reason_class(_reason), do: "authority_horizon_exception"

  defp stable_reason_message(reason_class) when is_binary(reason_class) do
    Enum.find_value(
      @stable_reason_messages,
      "authority horizon preflight failed closed",
      fn {atom, message} ->
        if Atom.to_string(atom) == reason_class, do: message
      end
    )
  end

  defp stable_reason_message(_reason_class),
    do: "authority horizon preflight failed closed"
end
