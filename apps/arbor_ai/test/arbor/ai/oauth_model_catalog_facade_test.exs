defmodule Arbor.AI.OAuthModelCatalogFacadeTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.{ProviderModelCatalogRefresh, ProviderModelCatalogStore}
  alias Arbor.Contracts.LLM.ProviderModelCatalog
  alias Arbor.LLM.OAuth.CredentialReceipt

  @moduletag :fast

  @observed_at ~U[2026-07-29 12:00:00Z]
  @expires_at ~U[2026-07-29 12:05:00Z]

  setup do
    ensure_store_running()
    ProviderModelCatalogStore.clear_sync(:openai_oauth)
    ProviderModelCatalogStore.clear_sync(:xai_oauth)
    :ok
  end

  test "public refresh rejects callback injectors that would forge cache state" do
    flunk_fun = fn _ -> flunk("public refresh must not invoke injected callbacks") end
    flunk_clock = fn -> flunk("public refresh must not invoke injected clocks") end

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth,
               credential_receipt_fun: flunk_fun
             )

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, request_fun: flunk_fun)

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, now_fn: flunk_clock)

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, clock: flunk_clock)

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth,
               reread_source_credential_fun: flunk_fun
             )

    assert {:error, :miss} = Arbor.AI.fetch_oauth_model_catalog(:openai_oauth)
  end

  test "public refresh admits only closed non-callback timeout option shape" do
    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, timeout_ms: 0)

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, timeout_ms: 100_000)

    assert {:error, :invalid_options} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, unknown: 1)

    assert {:error, :keyword_options_required} =
             Arbor.AI.refresh_oauth_model_catalog(:openai_oauth, %{})
  end

  test "internal refresh_via_llm publishes contract-valid catalog for same-app tests" do
    assert {:ok, %ProviderModelCatalog{} = catalog} =
             ProviderModelCatalogRefresh.refresh_via_llm(:openai_oauth,
               credential_receipt_fun: fn :openai ->
                 {:ok, receipt(:openai, "arbor_owned", 3, "tok-openai", "acct-1")}
               end,
               request_fun: fn _spec ->
                 json_ok(%{
                   "models" => [
                     %{"slug" => "gpt-facade", "supported_in_api" => true}
                   ]
                 })
               end,
               now_fn: fn -> @observed_at end
             )

    assert catalog.route == "openai_oauth"
    assert catalog.model_ids == ["gpt-facade"]
    assert catalog.credential_generation == 3

    assert {:ok, cached} = Arbor.AI.fetch_oauth_model_catalog(:openai_oauth)
    assert cached.model_ids == ["gpt-facade"]

    assert {:ok, snap} = Arbor.AI.oauth_model_catalog_snapshot()
    assert snap["openai_oauth"]["model_ids"] == ["gpt-facade"]
    refute Map.has_key?(snap["openai_oauth"], "access_token")
  end

  test "last-mile publish composes validated catalog with store without public clear" do
    assert {:ok, good} =
             ProviderModelCatalog.new(%{
               route: "openai_oauth",
               backend: "openai",
               runtime: "arbor",
               model_ids: ["keep"],
               observed_at: DateTime.to_iso8601(@observed_at),
               expires_at: DateTime.to_iso8601(@expires_at),
               credential_generation: 1
             })

    assert {:ok, ^good} = ProviderModelCatalogRefresh.publish(good)
    assert {:ok, kept} = Arbor.AI.fetch_oauth_model_catalog("openai_oauth")
    assert kept.model_ids == ["keep"]

    # Failed LLM refresh (internal test seam) does not erase last-good.
    assert {:error, _reason} =
             ProviderModelCatalogRefresh.refresh_via_llm(:openai_oauth,
               credential_receipt_fun: fn :openai ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _spec ->
                 {:ok, %{status: 500, body: "{}", headers: []}}
               end,
               now_fn: fn -> @observed_at end
             )

    assert {:ok, still} = Arbor.AI.fetch_oauth_model_catalog("openai_oauth")
    assert still.model_ids == ["keep"]

    # Clear is store-internal only — not a public Arbor.AI command.
    refute function_exported?(Arbor.AI, :clear_oauth_model_catalog, 1)
    assert :ok = ProviderModelCatalogStore.clear_sync(:openai_oauth)
    assert {:error, :miss} = Arbor.AI.fetch_oauth_model_catalog(:openai_oauth)
  end

  test "fetch and snapshot perform no network or credential work" do
    assert {:ok, good} =
             ProviderModelCatalog.new(%{
               route: "xai_oauth",
               backend: "xai",
               runtime: "arbor",
               model_ids: ["cached-only"],
               observed_at: DateTime.to_iso8601(@observed_at),
               expires_at: DateTime.to_iso8601(@expires_at),
               credential_generation: 2
             })

    assert :ok = ProviderModelCatalogStore.put_sync(good)

    assert {:ok, cached} = Arbor.AI.fetch_oauth_model_catalog(:xai_oauth)
    assert cached.model_ids == ["cached-only"]
    assert {:ok, %{"xai_oauth" => entry}} = Arbor.AI.oauth_model_catalog_snapshot()
    assert entry["model_ids"] == ["cached-only"]
    refute Map.has_key?(entry, "access_token")
    refute Map.has_key?(entry, "account_id")
  end

  test "rejected aliases fail closed on public refresh and fetch" do
    assert {:error, _reason} = Arbor.AI.refresh_oauth_model_catalog(:openai, [])
    assert {:error, _reason} = Arbor.AI.refresh_oauth_model_catalog("grok", [])
    assert {:error, :rejected} = Arbor.AI.fetch_oauth_model_catalog(:openai)
    assert {:error, :miss} = Arbor.AI.fetch_oauth_model_catalog(:openai_oauth)
  end

  test "store unavailability surfaces through the read facade" do
    assert :ok = Supervisor.terminate_child(Arbor.AI.Supervisor, ProviderModelCatalogStore)
    assert Process.whereis(ProviderModelCatalogStore) == nil

    try do
      assert {:error, :unavailable} = Arbor.AI.fetch_oauth_model_catalog(:openai_oauth)
      assert {:error, :unavailable} = Arbor.AI.oauth_model_catalog_snapshot()
    after
      ensure_store_running()
    end
  end

  defp receipt(provider, owner, generation, token, account_id) do
    %CredentialReceipt{
      provider: provider,
      owner: owner,
      access_token: token,
      account_id: account_id,
      generation: generation
    }
  end

  defp json_ok(map) do
    {:ok,
     %{
       status: 200,
       body: Jason.encode!(map),
       headers: %{"content-type" => ["application/json"]}
     }}
  end

  defp ensure_store_running do
    case Process.whereis(ProviderModelCatalogStore) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Supervisor.restart_child(Arbor.AI.Supervisor, ProviderModelCatalogStore) do
          {:ok, _} ->
            :ok

          {:ok, _, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, :not_found} ->
            {:ok, _} = Supervisor.start_child(Arbor.AI.Supervisor, ProviderModelCatalogStore)
            :ok

          other ->
            flunk("failed to restart ProviderModelCatalogStore: #{inspect(other)}")
        end
    end

    assert is_pid(Process.whereis(ProviderModelCatalogStore))
  end
end
