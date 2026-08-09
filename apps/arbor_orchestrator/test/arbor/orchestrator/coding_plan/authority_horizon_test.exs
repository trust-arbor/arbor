defmodule Arbor.Orchestrator.CodingPlan.AuthorityHorizonTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.{
    AuthorityHorizon,
    AuthorityHorizonCore,
    ExecutionManifest
  }
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler
  alias Arbor.Orchestrator.Middleware.CapabilityCheck
  alias Arbor.Orchestrator.Viz.DotSerializer

  defmodule HorizonSecurity do
    @moduledoc false

    def list_capabilities(principal_id, opts) do
      case Process.get({:horizon_caps, principal_id}) do
        nil -> {:ok, []}
        fun when is_function(fun, 2) -> fun.(principal_id, opts)
        caps when is_list(caps) -> {:ok, caps}
        reply -> reply
      end
    end

    def capability_authorizes?(capability, resource, opts) do
      case Process.get(:horizon_authorizes) do
        fun when is_function(fun, 3) ->
          fun.(capability, resource, opts)

        _ ->
          resources = Map.get(capability, :resources) || Map.get(capability, "resources") || []
          task_id = Keyword.get(opts, :task_id)
          cap_task = Map.get(capability, :task_id) || Map.get(capability, "task_id")

          task_ok? = is_nil(cap_task) or cap_task == task_id
          resource_ok? = resource in resources or :all in resources
          task_ok? and resource_ok?
      end
    end

    def normalize_authorization_resource_uri(resource, _opts), do: {:ok, resource}
  end

  setup do
    Process.delete(:horizon_authorizes)
    :ok
  end

  describe "derive_required_resources/2" do
    test "unions compiled node resources with transitive action capability URIs" do
      {:ok, graph} = minimal_compiled_graph()

      nested_only_uri = "arbor://action/coding/review/submit"
      top_action_uri = "arbor://action/coding/acquire_workspace"

      manifest = %{
        "version" => 2,
        "capability_uris" => [top_action_uri, nested_only_uri],
        "nested_graphs" => []
      }

      assert {:ok, resources} = AuthorityHorizon.derive_required_resources(graph, manifest)
      assert top_action_uri in resources
      assert nested_only_uri in resources
      # Node-derived orchestrator execute URI from the compiled start/done/exec shape.
      assert Enum.any?(resources, &String.starts_with?(&1, "arbor://"))
    end

    test "entry/exit sentinels do not contribute a placeholder capability" do
      # start [shape=Mdiamond] / done [shape=Msquare] carry no `type` attribute
      # because they execute nothing. CapabilityCheck.capability_resources/1
      # falls back to "arbor://orchestrator/execute/" <> type, defaulting the
      # missing type to the literal string "unknown".
      #
      # At RUNTIME that default is deliberate fail-closed behaviour and must
      # stay. In PREFLIGHT it made every coding dispatch demand
      # `arbor://orchestrator/execute/unknown` from the caller — a parse
      # placeholder, not a permission. Nobody would think to grant it, and
      # granting it would be meaningless, so admission failed with
      # authority_horizon_missing on an otherwise correctly authorized caller.
      {:ok, graph} = minimal_compiled_graph()

      manifest = %{"version" => 2, "capability_uris" => [], "nested_graphs" => []}

      assert {:ok, resources} = AuthorityHorizon.derive_required_resources(graph, manifest)

      refute "arbor://orchestrator/execute/unknown" in resources,
             "sentinel nodes must not contribute a placeholder capability to the " <>
               "caller's required set"
    end

    test "hash-verifies a reviewed nested graph and includes its node-only resources" do
      {:ok, top} = minimal_compiled_graph()
      top_only = MapSet.new(top_node_resources(top))

      nested_id = "code_review_council"
      assert {:ok, reviewed} = Arbor.Actions.reviewed_pipeline(nested_id)
      source = reviewed.source
      assert is_binary(source) and source != ""

      assert {:ok, nested_graph} = Parser.parse(source)
      assert {:ok, nested_compiled} = IRCompiler.compile(nested_graph)

      graph_hash =
        nested_compiled
        |> DotSerializer.serialize()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert {:ok, compiled_graph_hash} = ExecutionManifest.compiled_graph_hash(nested_compiled)

      nested_node_resources = top_node_resources(nested_compiled)
      # Nested graph must contribute at least one resource not present on the
      # minimal top-level start/done graph alone.
      nested_only =
        nested_node_resources
        |> MapSet.new()
        |> MapSet.difference(top_only)
        |> MapSet.to_list()

      assert nested_only != [],
             "expected nested reviewed graph to contribute node resources absent from top-level"

      # Intentionally omit nested capability_uris / action URIs so the only way
      # nested_only resources enter the complete set is via hash-verified
      # nested node compilation — not top-level manifest action merge.
      manifest = %{
        "version" => 3,
        "capability_uris" => [],
        "nested_graphs" => [
          %{
            "id" => nested_id,
            "graph_hash" => graph_hash,
            "compiled_graph_hash" => compiled_graph_hash,
            "execution_manifest" => %{
              "capability_uris" => []
            }
          }
        ]
      }

      assert {:ok, resources} = AuthorityHorizon.derive_required_resources(top, manifest)
      resource_set = MapSet.new(resources)

      Enum.each(nested_only, fn uri ->
        assert MapSet.member?(resource_set, uri),
               "missing nested node resource #{uri} from complete set"
      end)

      # Drift fails closed: wrong hash must not silently drop nested requirements.
      drifted =
        put_in(manifest, ["nested_graphs", Access.at(0), "graph_hash"], String.duplicate("0", 64))

      assert {:error, :nested_graph_authority_drift} =
               AuthorityHorizon.derive_required_resources(top, drifted)
    end

    test "fails closed on nested graph entry without verified hashes" do
      {:ok, graph} = minimal_compiled_graph()

      manifest = %{
        "version" => 3,
        "capability_uris" => [],
        "nested_graphs" => [
          %{
            "id" => "code_review_council",
            "execution_manifest" => %{"capability_uris" => []}
          }
        ]
      }

      assert {:error, :nested_graph_authority_drift} =
               AuthorityHorizon.derive_required_resources(graph, manifest)
    end
  end

  describe "preflight/1" do
    setup do
      {:ok, graph} = minimal_compiled_graph()
      resource = "arbor://action/coding/acquire_workspace"

      base_opts = [
        security: HorizonSecurity,
        execution_principal: "agent_exec",
        task_id: "task_horizon_1",
        compiled_graph: graph,
        execution_manifest: %{
          "version" => 2,
          "capability_uris" => [resource]
        },
        run_deadline_unix_ms: System.system_time(:millisecond) + 60_000,
        cleanup_reserve_ms: 30_000,
        now: DateTime.utc_now()
      ]

      %{base_opts: base_opts, resource: resource, graph: graph}
    end

    test "accepts permanent authority", %{base_opts: opts} do
      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all], task_id: "task_horizon_1"}
      ])

      assert :ok = AuthorityHorizon.preflight(opts)
    end

    test "accepts adequate finite authority", %{base_opts: opts} do
      horizon_ms = opts[:run_deadline_unix_ms] + opts[:cleanup_reserve_ms]
      {:ok, horizon_dt} = DateTime.from_unix(horizon_ms, :millisecond)

      Process.put({:horizon_caps, "agent_exec"}, [
        %{
          expires_at: DateTime.add(horizon_dt, 120, :second),
          resources: [:all],
          task_id: "task_horizon_1"
        }
      ])

      assert :ok = AuthorityHorizon.preflight(opts)
    end

    test "rejects missing authority with admission diagnostic shape", %{
      base_opts: opts
    } do
      Process.put({:horizon_caps, "agent_exec"}, [])

      assert {:error, {:authority_horizon_diagnostic, diagnostic}} =
               AuthorityHorizon.preflight(opts)

      assert diagnostic["gate_id"] == "authority_horizon"
      assert diagnostic["code"] == "authority_horizon_missing"
      assert diagnostic["phase"] == "preflight"
      assert diagnostic["decision"] == "blocked"
    end

    test "rejects expiring authority", %{base_opts: opts} do
      horizon_ms = opts[:run_deadline_unix_ms] + opts[:cleanup_reserve_ms]
      {:ok, horizon_dt} = DateTime.from_unix(horizon_ms, :millisecond)

      Process.put({:horizon_caps, "agent_exec"}, [
        %{
          expires_at: DateTime.add(horizon_dt, -5, :second),
          resources: [:all],
          task_id: "task_horizon_1"
        }
      ])

      assert {:error, {:authority_horizon_diagnostic, diagnostic}} =
               AuthorityHorizon.preflight(opts)

      assert diagnostic["code"] == "authority_horizon_expiring"
    end

    test "same-principal caller is deduplicated", %{base_opts: opts} do
      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all], task_id: "task_horizon_1"}
      ])

      assert :ok =
               AuthorityHorizon.preflight(Keyword.put(opts, :caller_id, "agent_exec"))
    end

    test "distinct caller requires intersection of authority", %{
      base_opts: opts
    } do
      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all], task_id: "task_horizon_1"}
      ])

      Process.put({:horizon_caps, "caller_other"}, [])

      assert {:error, {:authority_horizon_diagnostic, diagnostic}} =
               AuthorityHorizon.preflight(Keyword.put(opts, :caller_id, "caller_other"))

      assert diagnostic["code"] == "authority_horizon_missing"

      assert diagnostic["message"] =~ "authenticated_caller" or
               diagnostic["evidence_ref"] =~ "missing_n="
    end

    test "exact task scope rejects wrong task-bound caps", %{base_opts: opts} do
      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all], task_id: "task_other"}
      ])

      assert {:error, {:authority_horizon_diagnostic, diagnostic}} =
               AuthorityHorizon.preflight(opts)

      assert diagnostic["code"] == "authority_horizon_missing"
    end
  end

  describe "project/1" do
    setup do
      {:ok, graph} = minimal_compiled_graph()
      resource = "arbor://action/coding/acquire_workspace"
      now = ~U[2026-08-06 12:00:00.000000Z]
      run_deadline = DateTime.to_unix(now, :millisecond) + 60_000

      base_opts = [
        security: HorizonSecurity,
        execution_principal: "agent_exec",
        compiled_graph: graph,
        execution_manifest: %{
          "version" => 2,
          "capability_uris" => [resource]
        },
        run_deadline_unix_ms: run_deadline,
        cleanup_reserve_ms: 30_000,
        now: now,
        scope_mode: :future_task
      ]

      %{base_opts: base_opts, resource: resource, now: now, run_deadline: run_deadline}
    end

    test "projects distinct caller missing and execution expiring with exact counts/digests", %{
      base_opts: opts,
      resource: resource,
      run_deadline: run_deadline
    } do
      # Minimal start/done graph contributes no node resources (sentinels
      # excluded), so the complete required set is exactly the manifest URI.
      horizon_ms = run_deadline + 30_000
      {:ok, horizon_dt} = DateTime.from_unix(horizon_ms, :millisecond)

      Process.put({:horizon_caps, "agent_exec"}, [
        %{
          expires_at: DateTime.add(horizon_dt, -5, :second),
          resources: [resource]
        }
      ])

      Process.put({:horizon_caps, "caller_other"}, [])

      assert {:ok, report} =
               AuthorityHorizon.project(Keyword.put(opts, :caller_id, "caller_other"))

      assert report["kind"] == "authority_horizon_projection"
      assert report["status"] == "missing"
      assert report["scope"]["mode"] == "future_task"
      assert report["scope"]["task_id"] == nil
      assert report["scope"]["session_id"] == nil
      assert report["error"] == nil

      assert report["required_resources"]["total_count"] == 1
      assert report["required_resources"]["resource_uris"] == [resource]

      assert report["required_resources"]["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest([resource])

      exec_expiring =
        Enum.find(report["findings"], fn f ->
          f["principal_role"] == "execution_principal" and f["classification"] == "expiring"
        end)

      caller_missing =
        Enum.find(report["findings"], fn f ->
          f["principal_role"] == "authenticated_caller" and f["classification"] == "missing"
        end)

      assert exec_expiring["total_count"] == 1
      assert exec_expiring["resource_uris"] == [resource]

      assert exec_expiring["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest([resource])

      assert caller_missing["total_count"] == 1
      assert caller_missing["resource_uris"] == [resource]

      assert caller_missing["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest([resource])

      assert report["summary"]["missing_n"] == 1
      assert report["summary"]["expiring_n"] == 1

      expected_findings_digest =
        AuthorityHorizonCore.project_horizon_report(%{
          findings: [
            %{
              role: :execution_principal,
              classification: :expiring,
              resource_uris: [resource],
              total_count: 1
            },
            %{
              role: :authenticated_caller,
              classification: :missing,
              resource_uris: [resource],
              total_count: 1
            }
          ],
          resources: [resource],
          status: "missing"
        })["summary"]["findings_digest"]

      assert report["summary"]["findings_digest"] == expected_findings_digest

      assert {:ok, report2} =
               AuthorityHorizon.project(Keyword.put(opts, :caller_id, "caller_other"))

      assert report2["summary"]["findings_digest"] == report["summary"]["findings_digest"]
      assert Jason.encode!(report)
      refute inspect(report) =~ "capability_id"
    end

    test "bounds finding URI samples above the projection limit while retaining digests", %{
      base_opts: opts
    } do
      uris =
        for i <- 1..70 do
          "arbor://resource/#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        end

      opts =
        Keyword.put(opts, :execution_manifest, %{
          "version" => 2,
          "capability_uris" => uris
        })

      Process.put({:horizon_caps, "agent_exec"}, [])

      assert {:ok, report} = AuthorityHorizon.project(opts)

      assert report["required_resources"]["total_count"] == 70

      assert length(report["required_resources"]["resource_uris"]) ==
               AuthorityHorizonCore.projected_uri_limit()

      assert report["required_resources"]["resource_uris"] ==
               Enum.take(Enum.sort(uris), AuthorityHorizonCore.projected_uri_limit())

      assert report["required_resources"]["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest(Enum.sort(uris))

      [missing] = report["findings"]
      assert missing["classification"] == "missing"
      assert missing["total_count"] == 70

      assert length(missing["resource_uris"]) == AuthorityHorizonCore.projected_uri_limit()

      assert missing["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest(Enum.sort(uris))

      assert report["summary"]["missing_n"] == 70
    end

    test "malformed non-keyword opts never raise and return a bounded error" do
      assert {:ok, report} = AuthorityHorizon.project([:bad])
      assert report["status"] == "error"
      assert report["kind"] == "authority_horizon_projection"
      assert is_map(report["error"])
      assert report["error"]["code"] == "invalid_authority_horizon_opts"
      assert is_binary(report["error"]["message"])
      assert Jason.encode!(report)
    end

    test "future-task forces null scope ids and empty Security scope opts", %{
      base_opts: opts,
      resource: resource
    } do
      Process.put({:horizon_caps, "agent_exec"}, fn _principal_id, scope_opts ->
        send(self(), {:future_task_scope_opts, scope_opts})
        {:ok, [%{expires_at: nil, resources: [resource], task_id: "task_some_existing"}]}
      end)

      # Even if a caller tries to smuggle task/session into project opts, future
      # task mode must not put them in Security scope or the report.
      smuggled =
        opts
        |> Keyword.put(:task_id, "task_should_not_appear")
        |> Keyword.put(:session_id, "session_should_not_appear")

      assert {:ok, report} = AuthorityHorizon.project(smuggled)

      assert report["scope"]["mode"] == "future_task"
      assert report["scope"]["task_id"] == nil
      assert report["scope"]["session_id"] == nil
      assert report["status"] == "missing"

      assert_received {:future_task_scope_opts, []}

      missing =
        Enum.find(report["findings"], fn f ->
          f["principal_role"] == "execution_principal" and f["classification"] == "missing"
        end)

      assert missing["total_count"] == 1
    end

    test "future-task credits permanent non-task-scoped capabilities", %{
      base_opts: opts,
      resource: resource
    } do
      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all]}
      ])

      assert {:ok, report} = AuthorityHorizon.project(opts)
      assert report["status"] == "ready"
      assert report["findings"] == []
      assert report["summary"]["missing_n"] == 0
      assert report["summary"]["expiring_n"] == 0
      assert report["scope"]["task_id"] == nil
      assert report["scope"]["session_id"] == nil
      assert report["required_resources"]["resource_uris"] == [resource]
    end

    test "bound_task scope still requires an exact task id for task-scoped caps", %{
      base_opts: opts
    } do
      bound_opts =
        opts
        |> Keyword.put(:scope_mode, :bound_task)
        |> Keyword.put(:task_id, "task_horizon_1")

      Process.put({:horizon_caps, "agent_exec"}, [
        %{expires_at: nil, resources: [:all], task_id: "task_horizon_1"}
      ])

      assert {:ok, ready} = AuthorityHorizon.project(bound_opts)
      assert ready["status"] == "ready"
      assert ready["scope"]["mode"] == "bound_task"
      assert ready["scope"]["task_id"] == "task_horizon_1"
    end
  end

  defp minimal_compiled_graph do
    # Minimal valid DOT that IR-compiles; node capability resources come from
    # CapabilityCheck.capability_resources/1, not handler-name invention.
    source = """
    digraph G {
      start [shape=Mdiamond];
      done [shape=Msquare];
      start -> done;
    }
    """

    with {:ok, graph} <- Parser.parse(source),
         {:ok, compiled} <- IRCompiler.compile(graph) do
      {:ok, compiled}
    else
      # Fallback synthetic compiled graph if parser shape differs.
      _ ->
        node = %Node{
          id: "start",
          attrs: %{"type" => "start", "shape" => "Mdiamond"},
          capabilities_required: []
        }

        {:ok,
         %Graph{
           nodes: %{"start" => node},
           edges: [],
           adjacency: %{},
           reverse_adjacency: %{},
           compiled: true,
           capabilities_required: MapSet.new(),
           handler_types: %{},
           attrs: %{}
         }}
    end
  end

  defp top_node_resources(%Graph{nodes: nodes}) when is_map(nodes) do
    nodes
    |> Map.values()
    |> Enum.flat_map(&CapabilityCheck.capability_resources/1)
    |> Enum.uniq()
  end
end
