defmodule Arbor.AI.ProviderRouteReadinessTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.{ProviderModelCatalogStore, ProviderRouteReadiness}
  alias Arbor.AI.Runtime.RouteInputAssembler
  alias Arbor.Contracts.LLM.{OAuthHealth, ProviderModelCatalog}
  alias Arbor.LLM.OAuth

  @moduletag :fast
  @now ~U[2026-07-31 12:00:00Z]

  setup do
    stop_readiness()
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    on_exit(fn ->
      stop_readiness()

      try do
        if Process.alive?(task_supervisor), do: GenServer.stop(task_supervisor)
      catch
        :exit, _ -> :ok
      end
    end)

    %{task_supervisor: task_supervisor}
  end

  test "init returns startup-blocked before the asynchronous observation", %{
    task_supervisor: task_supervisor
  } do
    parent = self()

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn ->
          send(parent, {:requirements_started, self()})

          receive do
            :release_requirements -> {:ok, enabled_requirements()}
          end
        end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn -> {:ok, %{"openai_oauth" => catalog_map(3)}} end,
        health_reader: fn _ -> {:ok, ready_health(3)} end
      )

    assert_receive {:requirements_started, observation_task}
    assert ProviderRouteReadiness.status()["state"] == "startup_blocked"
    refute_receive :refresh_called, 20

    send(observation_task, :release_requirements)
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
  end

  test "disabled profile preserves legacy behavior", %{task_supervisor: task_supervisor} do
    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, %{enabled: false, required_routes: [], binding: []}} end,
        evidence_reader: fn -> raise "disabled profile must not read durable evidence" end,
        catalog_reader: fn -> raise "disabled profile must not read catalog" end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "disabled" end)
    assert {:ok, :disabled} = ProviderRouteReadiness.ensure_ready(disabled_requirements())
  end

  test "durable replay pending blocks without refreshing", %{task_supervisor: task_supervisor} do
    parent = self()

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :replaying} end,
        catalog_reader: fn -> {:ok, %{}} end,
        health_reader: fn _ -> {:ok, ready_health(3)} end,
        refresh_fun: fn _route, _opts ->
          send(parent, :refresh_called)
          {:error, :request_timeout}
        end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "durable_replay_pending" end)
    refute_receive :refresh_called, 20
    assert {:error, :not_ready} = ProviderRouteReadiness.ensure_ready(enabled_requirements())
  end

  test "missing catalog is refreshed asynchronously and readiness binds the exact route set", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, catalog_state} = Agent.start_link(fn -> %{} end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn -> {:ok, Agent.get(catalog_state, & &1)} end,
        health_reader: fn _ -> {:ok, ready_health(3)} end,
        refresh_fun: fn route, _opts ->
          send(parent, {:refresh_called, route})
          Agent.update(catalog_state, &Map.put(&1, route, catalog_map(3)))
          {:ok, catalog(3)}
        end
      )

    assert_receive {:refresh_called, "openai_oauth"}, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
    assert :ok = ProviderRouteReadiness.ensure_ready(enabled_requirements())

    changed = %{
      enabled: true,
      required_routes: ["xai_oauth"],
      binding: [binding("xai_oauth", "grok-4.5")]
    }

    assert {:error, :route_set_changed} = ProviderRouteReadiness.ensure_ready(changed)
  end

  test "transient refresh failure preserves the last-good catalog", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    stale = catalog_map(3, expires_at: "2026-07-31T11:59:30Z")

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn -> {:ok, %{"openai_oauth" => stale}} end,
        health_reader: fn _ -> {:ok, ready_health(3)} end,
        refresh_fun: fn _route, _opts ->
          send(parent, :refresh_called)
          {:error, :request_timeout}
        end
      )

    assert_receive :refresh_called, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "catalog_refresh_transient" end)
    assert ProviderRouteReadiness.status()["ready"] == false
  end

  test "permanent auth failure blocks and manual refresh retries after reauthentication", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, health_state} = Agent.start_link(fn -> :login_required end)
    {:ok, catalog_state} = Agent.start_link(fn -> %{} end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn -> {:ok, Agent.get(catalog_state, & &1)} end,
        health_reader: fn _ ->
          case Agent.get(health_state, & &1) do
            :login_required -> {:ok, login_required_health()}
            :ready -> {:ok, ready_health(3)}
          end
        end,
        refresh_fun: fn route, _opts ->
          send(parent, :refresh_called)
          Agent.update(catalog_state, &Map.put(&1, route, catalog_map(3)))
          {:ok, catalog(3)}
        end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "oauth_health_permanent" end)
    refute_receive :refresh_called, 20

    Agent.update(health_state, fn _ -> :ready end)
    assert {:ok, :scheduled} = ProviderRouteReadiness.manual_refresh()
    assert_receive :refresh_called, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
  end

  test "expired health refreshes asynchronously and rereads health plus catalog", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, health_state} = Agent.start_link(fn -> {:expired, 3} end)
    {:ok, catalog_state} = Agent.start_link(fn -> %{"openai_oauth" => catalog_map(3)} end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn ->
          send(parent, :catalog_read)
          {:ok, Agent.get(catalog_state, & &1)}
        end,
        health_reader: fn _ ->
          send(parent, :health_read)

          case Agent.get(health_state, & &1) do
            {:expired, generation} -> {:ok, health("expired", generation)}
            {:ready, generation} -> {:ok, ready_health(generation)}
          end
        end,
        refresh_fun: fn route, _opts ->
          send(parent, :refresh_called)
          Agent.update(health_state, fn _ -> {:ready, 4} end)
          Agent.update(catalog_state, &Map.put(&1, route, catalog_map(4)))
          {:ok, catalog(4)}
        end
      )

    assert_receive :refresh_called, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
    assert_received :health_read
    assert_received :health_read
    assert_received :catalog_read
    assert_received :catalog_read
    assert :ok = ProviderRouteReadiness.ensure_ready(enabled_requirements())
  end

  test "trusted background refresh can replace a contract-invalid cached catalog", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, catalog_state} = Agent.start_link(fn -> %{"openai_oauth" => %{"bad" => true}} end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn -> {:ok, Agent.get(catalog_state, & &1)} end,
        health_reader: fn _ -> {:ok, ready_health(3)} end,
        refresh_fun: fn route, _opts ->
          send(parent, :refresh_called)
          Agent.update(catalog_state, &Map.put(&1, route, catalog_map(3)))
          {:ok, catalog(3)}
        end
      )

    assert_receive :refresh_called, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
  end

  test "invalid clock fails closed without consulting evidence or real time", %{
    task_supervisor: task_supervisor
  } do
    {:ok, _pid} =
      start_readiness(task_supervisor,
        clock: fn -> :not_a_datetime end,
        requirements_reader: fn -> raise "invalid clock must stop before profile observation" end,
        evidence_reader: fn -> raise "invalid clock must stop before evidence observation" end,
        catalog_reader: fn -> raise "invalid clock must stop before catalog observation" end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "malformed_input" end)
    assert ProviderRouteReadiness.status()["checked_at"] == nil
    assert ProviderRouteReadiness.status()["ready"] == false
  end

  test "valid catalog refreshes before the next observation can cross its expiry", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, clock_state} = Agent.start_link(fn -> @now end)
    {:ok, catalog_state} = Agent.start_link(fn -> nil end)

    last_good =
      catalog_map(3,
        observed_at: "2026-07-31T11:59:00Z",
        expires_at: "2026-07-31T12:00:46Z"
      )

    Agent.update(catalog_state, fn _ -> last_good end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        clock: fn -> Agent.get(clock_state, & &1) end,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn ->
          {:ok, %{"openai_oauth" => Agent.get(catalog_state, & &1)}}
        end,
        health_reader: fn _ ->
          send(parent, :health_read)
          {:ok, ready_health(3)}
        end,
        refresh_fun: fn _route, _opts ->
          send(parent, :refresh_called)

          renewed =
            catalog_map(3,
              observed_at: "2026-07-31T12:00:01Z",
              expires_at: "2026-07-31T12:05:01Z"
            )

          Agent.update(catalog_state, fn _ -> renewed end)
          {:ok, catalog(3)}
        end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
    assert_receive :health_read, 1_000
    refute_receive :refresh_called, 20

    Agent.update(clock_state, fn _ -> DateTime.add(@now, 1, :second) end)
    assert {:ok, :scheduled} = ProviderRouteReadiness.manual_refresh()
    assert_receive :refresh_called, 1_000

    eventually(fn ->
      ProviderRouteReadiness.status()["state"] == "ready" and
        ProviderRouteReadiness.status()["checked_at"] == "2026-07-31T12:00:01Z"
    end)
  end

  test "transient proactive refresh retries while the last-good catalog is still usable", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, catalog_state} =
      Agent.start_link(fn -> catalog_map(3, expires_at: "2026-07-31T12:00:30Z") end)

    {:ok, _pid} =
      start_readiness(task_supervisor,
        requirements_reader: fn -> {:ok, enabled_requirements()} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: fn ->
          {:ok, %{"openai_oauth" => Agent.get(catalog_state, & &1)}}
        end,
        health_reader: fn _ -> {:ok, ready_health(3)} end,
        refresh_fun: fn _route, _opts ->
          attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
          send(parent, {:refresh_called, attempt})

          if attempt == 1 do
            {:error, :request_timeout}
          else
            Agent.update(catalog_state, fn _ -> catalog_map(3) end)
            {:ok, catalog(3)}
          end
        end
      )

    assert_receive {:refresh_called, 1}, 1_000
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
    assert_receive {:refresh_called, 2}, 1_500
    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
  end

  test "production jitter is bounded and nonzero" do
    assert Enum.all?(1..32, fn _ -> ProviderRouteReadiness.default_jitter(250) in 1..250 end)
    assert ProviderRouteReadiness.default_jitter(0) == 0
  end

  test "requirements reject disabled authority, blank models, extras, and duplicates" do
    malformed = [
      %{enabled: false, required_routes: ["openai_oauth"], binding: []},
      %{enabled: false, required_routes: [], binding: [binding("openai_oauth", "gpt-5.6")]},
      Map.put(disabled_requirements(), :extra, true),
      %{enabled: true, required_routes: ["openai_oauth"], binding: []},
      %{
        enabled: true,
        required_routes: ["openai_oauth"],
        binding: [binding("openai_oauth", "   ")]
      },
      %{
        enabled: true,
        required_routes: ["openai_oauth"],
        binding: [Map.put(binding("openai_oauth", "gpt-5.6"), "extra", true)]
      },
      %{
        enabled: true,
        required_routes: ["openai_oauth"],
        binding: [binding("openai_oauth", "gpt-5.6"), binding("openai_oauth", "gpt-5.6")]
      }
    ]

    Enum.each(malformed, fn requirements ->
      assert {:error, :malformed} = ProviderRouteReadiness.ensure_ready(requirements)
    end)
  end

  test "public production assembly gates on exact cached readiness without request-path refresh",
       %{
         task_supervisor: task_supervisor
       } do
    parent = self()
    Arbor.AI.TestSupport.ProviderRouteEvidence.reset!()
    root = Path.join(System.tmp_dir!(), "arbor-readiness-#{System.unique_integer([:positive])}")
    store_dir = Path.join(root, "oauth")
    File.mkdir_p!(store_dir)

    prior_profile = Application.get_env(:arbor_ai, :provider_route_profile)
    prior_store_dir = Application.get_env(:arbor_llm, :oauth_store_dir)
    prior_refresh = Application.get_env(:arbor_llm, :oauth_refresh_fun)
    {:ok, prior_catalogs} = ProviderModelCatalogStore.snapshot_sync()

    on_exit(fn ->
      restore_env(:arbor_ai, :provider_route_profile, prior_profile)
      restore_env(:arbor_llm, :oauth_store_dir, prior_store_dir)
      restore_env(:arbor_llm, :oauth_refresh_fun, prior_refresh)
      restore_catalogs(prior_catalogs)
      File.rm_rf(root)
    end)

    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _provider, _config, _token ->
      send(parent, :provider_callback_called)
      {:error, :must_not_run}
    end)

    {:ok, credential} =
      OAuth.AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_readiness_test",
        access_token: "opaque-readiness-access",
        refresh_token: "unused-readiness-refresh"
      })

    assert :ok = OAuth.publish_arbor_owned(:openai_oauth, credential)

    assert {:ok, %OAuthHealth{status: "ready", generation: generation}} =
             Arbor.LLM.oauth_health(:openai_oauth)

    now = DateTime.utc_now()
    production_catalog = production_catalog(generation, now)
    :ok = ProviderModelCatalogStore.clear_sync(:openai_oauth)
    :ok = ProviderModelCatalogStore.put_sync(production_catalog)

    Application.put_env(:arbor_ai, :provider_route_profile, production_profile())
    assert {:ok, requirements} = RouteInputAssembler.production_requirements()

    assert {:error, {:route_assembly_failed, {:provider_route_readiness, :unavailable}}} =
             AI.assemble_provider_route_input()

    refute_receive :provider_callback_called, 20

    {:ok, _pid} =
      start_readiness(task_supervisor,
        clock: &DateTime.utc_now/0,
        requirements_reader: fn -> {:ok, requirements} end,
        evidence_reader: fn -> %{status: :ready} end,
        catalog_reader: &ProviderModelCatalogStore.snapshot_sync/0,
        health_reader: &Arbor.LLM.oauth_health/1,
        refresh_fun: fn _route, _opts ->
          send(parent, :readiness_refresh_called)
          {:error, :must_not_run}
        end
      )

    eventually(fn -> ProviderRouteReadiness.status()["state"] == "ready" end)
    assert {:ok, input} = AI.assemble_provider_route_input()
    assert [%{canonical_id: "gpt-5.6-sol"}] = input.catalog
    refute_receive :provider_callback_called, 20
    refute_receive :readiness_refresh_called, 20
  end

  defp start_readiness(task_supervisor, opts) do
    ProviderRouteReadiness.start_link(
      Keyword.merge(
        [
          task_supervisor: task_supervisor,
          clock: fn -> @now end,
          jitter: fn _ -> 0 end
        ],
        opts
      )
    )
  end

  defp stop_readiness do
    case Process.whereis(ProviderRouteReadiness) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(_fun, 0),
    do: flunk("condition did not become true: #{inspect(ProviderRouteReadiness.status())}")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp disabled_requirements, do: %{enabled: false, required_routes: [], binding: []}

  defp enabled_requirements do
    %{
      enabled: true,
      required_routes: ["openai_oauth"],
      binding: [binding("openai_oauth", "gpt-5.6")]
    }
  end

  defp binding(route, model_id),
    do: %{"route" => route, "model_id" => model_id, "runtime" => "arbor"}

  defp ready_health(generation) do
    {:ok, health} =
      OAuthHealth.new(%{
        route: "openai_oauth",
        backend: "openai",
        status: "ready",
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store",
        generation: generation
      })

    health
  end

  defp login_required_health do
    {:ok, health} =
      OAuthHealth.new(%{route: "openai_oauth", backend: "openai", status: "login_required"})

    health
  end

  defp health(status, generation) do
    {:ok, health} =
      OAuthHealth.new(%{
        route: "openai_oauth",
        backend: "openai",
        status: status,
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store",
        generation: generation
      })

    health
  end

  defp catalog(generation), do: catalog!(generation)

  defp catalog!(generation) do
    {:ok, catalog} =
      ProviderModelCatalog.new(%{
        route: "openai_oauth",
        backend: "openai",
        runtime: "arbor",
        model_ids: ["gpt-5.6"],
        observed_at: "2026-07-31T11:59:00Z",
        expires_at: "2026-07-31T12:05:00Z",
        credential_generation: generation
      })

    catalog
  end

  defp catalog_map(generation, opts \\ []) do
    catalog!(generation)
    |> ProviderModelCatalog.to_map()
    |> Map.merge(Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end))
  end

  defp production_catalog(generation, now) do
    {:ok, catalog} =
      ProviderModelCatalog.new(%{
        route: "openai_oauth",
        backend: "openai",
        runtime: "arbor",
        model_ids: ["gpt-5.6-sol"],
        observed_at: DateTime.to_iso8601(DateTime.add(now, -1, :second)),
        expires_at: DateTime.to_iso8601(DateTime.add(now, 5, :minute)),
        credential_generation: generation
      })

    catalog
  end

  defp production_profile do
    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog_model_ids: ["gpt-5.6-sol"],
      scoreboard: [
        %{
          model: "gpt-5.6-sol",
          provider: "openai_oauth",
          runtime: "arbor",
          score: 1.0,
          dangerous_misses: 0,
          format_failure_rate: 0.0,
          variance: 0.0,
          marginal_cost: 0.0,
          latency_ms: 10
        }
      ],
      providers: ["openai_oauth"],
      params: %{}
    }
  end

  defp restore_catalogs(catalogs) do
    Enum.each([:openai_oauth, :xai_oauth], &ProviderModelCatalogStore.clear_sync/1)
    Enum.each(catalogs, fn {_route, catalog} -> ProviderModelCatalogStore.put_sync(catalog) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
