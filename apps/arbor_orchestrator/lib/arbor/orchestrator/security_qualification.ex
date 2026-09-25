defmodule Arbor.Orchestrator.SecurityQualification do
  @moduledoc """
  Source-owned preflight for operator-selected, qualified execution profiles.

  Evidence lives in the existing EvalRun store. Approval is an ordinary exact
  signed capability binding both the current profile and the complete evidence
  projection. A model-authored eval row, stale name, wildcard grant, or caller
  fingerprint is never qualification. Host configuration selects the run to use.
  Profiles without a configured requirement remain explicitly unqualified.
  """
  alias Arbor.Orchestrator.{ActionsExecutor, Config}
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.SecurityQualification.EvidenceCore
  alias Arbor.Orchestrator.Session.{ContextBuilder, TurnEgress}
  alias Arbor.Persistence

  @schema "arbor.security.qualification.v1"
  @checks ~w(hostile_export_journey audit_restart native_containment skill_revocation)
  @config_keys ~w(llm_provider llm_model llm_runtime llm_fallback_chain system_prompt tools stream temperature top_p max_tokens provider_options context_management effective_window preprocessor_enabled)a

  def required_checks, do: @checks

  def admit(state, source \\ :turn) do
    case Config.security_qualification(state.agent_id, source) do
      :unqualified ->
        :ok

      %{run_id: run_id} ->
        with {:ok, prepared} <- prepare(state, run_id, source),
             {:ok, caps} <- Arbor.Security.list_capabilities(state.agent_id),
             true <- Enum.any?(caps, &exact_approval?(&1, state.agent_id, prepared.approval_uri)) do
          :ok
        else
          _ -> {:error, :security_qualification_required}
        end

      _ ->
        {:error, :security_qualification_required}
    end
  rescue
    _ -> {:error, :security_qualification_required}
  catch
    _, _ -> {:error, :security_qualification_required}
  end

  def prepare(state, run_id, source \\ :turn) do
    with true <- valid_run_id?(run_id),
         {:ok, profile} <- capture(state, source),
         {:ok, run} <- Persistence.get_eval_run(run_id),
         {:ok, evidence} <- EvidenceCore.new(profile, run) |> EvidenceCore.show(),
         true <- artifact_digests_match?(evidence, profile),
         digest when is_binary(digest) <- Persistence.eval_config_fingerprint(evidence) do
      uri =
        "arbor://agent/security_qualification/" <>
          String.replace_prefix(profile.fingerprint, "sha256:", "") <>
          "/" <>
          String.replace_prefix(digest, "sha256:", "")

      {:ok, %{run_id: run_id, profile: profile, evidence_digest: digest, approval_uri: uri}}
    else
      _ -> {:error, :security_qualification_required}
    end
  rescue
    _ -> {:error, :security_qualification_required}
  catch
    _, _ -> {:error, :security_qualification_required}
  end

  def capture(state, source \\ :turn) do
    graph = Map.fetch!(state, :turn_graph)
    config = Map.fetch!(state, :config)

    with {:ok, %{route: route}} <- TurnEgress.resolve_frozen_route(state, graph),
         true <- route.runtime == "arbor",
         true <- (config["llm_fallback_chain"] || config[:llm_fallback_chain] || []) == [],
         true <- Config.preprocessor_enabled_for?(config) == false,
         {:ok, serving} <- Arbor.LLM.execution_provider_identity(route.provider, route.model),
         {:ok, transport} <- Arbor.LLM.stock_tool_transport_identity(route.provider),
         true <- transport["local_endpoint"] == true,
         {:ok, skills} <- Arbor.Memory.skill_version_manifest(state.agent_id),
         {:ok, producer} <- producer_identity(),
         {:ok, containment} <- Arbor.Shell.agent_execution_identity(),
         true <- containment["supported"] == true,
         {:ok, tools} <- tool_manifest(state),
         {:ok, workflow_digest} <- term_digest(graph),
         {:ok, manifest_graph} <- manifest_graph(graph, tools["selected"]),
         {:ok, action_catalog} <- ActionCatalog.snapshot(),
         {:ok, {_manifest, execution_digest}} <-
           ExecutionManifest.build(
             manifest_graph,
             action_catalog,
             String.replace_prefix(workflow_digest, "sha256:", "")
           ),
         {:ok, config_digest} <-
           term_digest(%{
             session: select_config(config),
             context_budgets: Config.context_budgets(),
             context_budget_enforcement: Config.context_budget_enforcement(),
             turn_timeout_ms: Config.turn_timeout_ms(),
             private_memory: Config.private_conversation_memory()
           }),
         {:ok, trust_policy} <- Arbor.Trust.execution_policy_snapshot(state.agent_id),
         true <- trust_policy.policy_enforcer_enabled and trust_policy.approval_guard_enabled,
         {:ok, permissions} <- Arbor.Security.execution_capability_snapshot(state.agent_id),
         security_policy = Arbor.Security.execution_policy_snapshot(),
         true <- enforcing_policy?(security_policy),
         {:ok, policy_digest} <-
           term_digest(%{
             security: security_policy,
             trust: trust_policy,
             actions: Arbor.Actions.execution_policy_snapshot()
           }),
         {:ok, skill_digest} <- term_digest(skills) do
      projection = %{
        "schema" => @schema,
        "source" => to_string(source),
        "provider" => route.provider,
        "model" => route.model,
        "runtime" => to_string(config["llm_runtime"] || config[:llm_runtime] || route.runtime),
        "serving" => serving,
        "tool_transport" => transport,
        "permissions" => permissions,
        "configuration_digest" => config_digest,
        "workflow_digest" => workflow_digest,
        "execution_manifest_digest" => execution_digest,
        "policy_digest" => policy_digest,
        "skills_digest" => skill_digest,
        "tools" => tools,
        "containment" => containment,
        "producer" => producer,
        "implementation" => implementation_manifest(),
        "corpus" => @checks,
        "grader_version" => "agent-stack-v1",
        "platform" => inspect(:os.type()),
        "otp" => to_string(:erlang.system_info(:otp_release))
      }

      case Persistence.eval_config_fingerprint(projection) do
        fingerprint when is_binary(fingerprint) ->
          {:ok, %{fingerprint: fingerprint, projection: projection}}

        _ ->
          {:error, :security_profile_unavailable}
      end
    else
      _ -> {:error, :security_profile_unavailable}
    end
  rescue
    _ -> {:error, :security_profile_unavailable}
  catch
    _, _ -> {:error, :security_profile_unavailable}
  end

  defp tool_manifest(state) do
    selected = ContextBuilder.resolve_session_tools(state)
    catalog = ActionsExecutor.build_action_map()
    modules = catalog |> Map.values() |> Enum.uniq() |> Enum.sort()

    # Jido's :function is a local callback whose serialized identity changes at
    # node restart. Bind the normalized model-visible schema, while retaining
    # the action owner's separate loaded-code descriptor.
    with {:ok, snapshot} <- ActionCatalog.snapshot(modules: modules) do
      Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
        with {:ok, descriptor} <- Arbor.Actions.runtime_descriptor(module),
             {:ok, action} <- ActionCatalog.fetch(snapshot, descriptor["name"]),
             {:ok, schema} <-
               action
               |> Map.take(["name", "description", "parameters_schema"])
               |> term_digest() do
          {:cont, {:ok, [%{"descriptor" => descriptor, "schema_digest" => schema} | acc]}}
        else
          _ -> {:halt, {:error, :tool_identity_unavailable}}
        end
      end)
      |> case do
        {:ok, descriptors} ->
          {:ok, %{"selected" => selected, "catalog" => Enum.reverse(descriptors)}}

        error ->
          error
      end
    end
  end

  # Session places this exact selection in context under session.tools. The
  # generic manifest requires explicit tool names, so bind a capture-only view.
  # Never execute this view; the original workflow digest remains in the profile.
  defp manifest_graph(graph, selected) when is_list(selected) do
    if Enum.all?(selected, &(is_binary(&1) and Regex.match?(~r/\A[A-Za-z0-9_]+\z/, &1))) do
      projected_nodes =
        Enum.reduce_while(graph.nodes, {:ok, %{}}, fn {id, node}, {:ok, nodes} ->
          attrs = node.attrs

          projected =
            if node.handler_module == Arbor.Orchestrator.Handlers.ComputeHandler and
                 Map.get(attrs, "use_tools") in [true, "true"] and
                 is_nil(Map.get(attrs, "tools")) do
              manifest_selected_tools(attrs, selected)
            else
              attrs
            end

          case manifest_action_attrs(node, projected) do
            {:ok, attrs} -> {:cont, {:ok, Map.put(nodes, id, %{node | attrs: attrs})}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case projected_nodes do
        {:ok, nodes} -> {:ok, %{graph | nodes: nodes}}
        {:error, _} = error -> error
      end
    else
      {:error, :unsupported_qualified_tool_selection}
    end
  end

  defp manifest_graph(_, _), do: {:error, :unsupported_qualified_tool_selection}

  defp manifest_selected_tools(attrs, []), do: Map.put(attrs, "use_tools", false)

  defp manifest_selected_tools(attrs, selected),
    do: Map.put(attrs, "tools", Enum.join(selected, ","))

  defp manifest_action_attrs(node, attrs) do
    if node.handler_module == Arbor.Orchestrator.Handlers.ExecHandler and
         Map.get(attrs, "target") == "action" do
      # The actual executor accepts dotted aliases; the catalog uses canonical
      # Jido names. Resolve through that owner so registry selection is bound too.
      with {:ok, %{descriptor: %{"name" => name}}} <-
             ActionsExecutor.resolve_execution_binding(Map.get(attrs, "action")) do
        {:ok, Map.put(attrs, "action", name)}
      end
    else
      {:ok, attrs}
    end
  end

  defp producer_identity do
    producer = Config.security_qualification_producer()

    with true <- is_atom(producer),
         {:module, ^producer} <- Code.ensure_loaded(producer),
         {:ok, identity} when is_map(identity) <-
           producer.security_qualification_producer_identity(),
         true <- :erlang.external_size(identity) <= 65_536 do
      {:ok, identity}
    else
      _ -> {:error, :qualification_producer_unavailable}
    end
  end

  defp artifact_digests_match?(evidence, profile) do
    Enum.all?(evidence["results"], fn result ->
      metadata = result["metadata"]

      matching_producer =
        result["sample_id"] != "hostile_export_journey" or
          metadata["producer_digest"] == profile.projection["producer"]["digest"]

      matching_producer and
        metadata["artifact_digest"] ==
          Persistence.eval_config_fingerprint(metadata["observations"])
    end)
  end

  defp enforcing_policy?(policy) do
    match?({:ok, %{"durability" => "node_restart"}}, Map.get(policy, :audit_identity)) and
      match?(
        {:ok,
         %{
           "mode" => "durable",
           "durability" => "durable",
           "serving" => true,
           "poisoned" => false,
           "torn_tail" => false
         }},
        Map.get(policy, :authority_journal)
      ) and
      Enum.all?(
        [
          :identity_verification,
          :capability_signing,
          :constraint_enforcement,
          :delegation_verification,
          :egress_enforcing,
          :uri_registry_enforcement
        ],
        &(Map.get(policy, &1) == true)
      ) and policy.invocation_audit == :required
  end

  defp exact_approval?(cap, agent_id, uri) do
    cap.resource_uri == uri and
      Arbor.Security.authorize_source_owned_exact_ordinary_capability(
        agent_id,
        uri,
        :execute,
        cap.id,
        %{session_id: nil, task_id: nil, principal_scope: nil, expected_egress: nil}
      ) == {:ok, :authorized}
  end

  defp valid_run_id?(id) when is_binary(id) and byte_size(id) in 1..256,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp valid_run_id?(_), do: false

  defp select_config(config) do
    Map.new(@config_keys, fn atom ->
      key = Atom.to_string(atom)
      {key, Map.get(config, key, Map.get(config, atom))}
    end)
  end

  defp implementation_manifest do
    for app <- [:arbor_orchestrator, :arbor_llm],
        module <- Enum.sort(Application.spec(app, :modules) || []) do
      Code.ensure_loaded!(module)

      %{
        "module" => Atom.to_string(module),
        "loaded_md5" => Base.encode16(module.module_info(:md5), case: :lower)
      }
    end
  end

  defp term_digest(value) do
    if :erlang.external_size(value) <= 1_048_576 do
      {:ok,
       "sha256:" <>
         Base.encode16(
           :crypto.hash(
             :sha256,
             :erlang.term_to_binary(value, [:deterministic])
           ),
           case: :lower
         )}
    else
      {:error, :profile_too_large}
    end
  end
end
