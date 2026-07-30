defmodule Arbor.AI.ProviderModelCatalogStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.ProviderModelCatalogStore
  alias Arbor.Contracts.LLM.ProviderModelCatalog

  @moduletag :fast

  @observed "2026-07-29T12:00:00Z"
  @expires "2026-07-29T12:05:00Z"
  @now ~U[2026-07-29 12:02:00Z]
  # Former finite put timeout that would make commit-after-timeout indeterminate.
  @former_finite_timeout_ms 1_000

  setup do
    ensure_store_running()
    ProviderModelCatalogStore.clear_sync(:openai_oauth)
    ProviderModelCatalogStore.clear_sync(:xai_oauth)
    :ok
  end

  test "exact-route isolation: openai and xai catalogs do not clobber each other" do
    assert {:ok, openai} = catalog("openai_oauth", "openai", ["gpt-a"], 1)
    assert {:ok, xai} = catalog("xai_oauth", "xai", ["grok-a"], 2)

    assert :ok = ProviderModelCatalogStore.put_sync(openai)
    assert :ok = ProviderModelCatalogStore.put_sync(xai)

    assert {:ok, got_o} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    assert {:ok, got_x} = ProviderModelCatalogStore.fetch_sync("xai_oauth")
    assert got_o.model_ids == ["gpt-a"]
    assert got_x.model_ids == ["grok-a"]
    assert got_o.credential_generation == 1
    assert got_x.credential_generation == 2

    assert {:ok, snap} = ProviderModelCatalogStore.snapshot_sync()
    assert Map.keys(snap) |> Enum.sort() == ["openai_oauth", "xai_oauth"]
    assert snap["openai_oauth"]["model_ids"] == ["gpt-a"]
    assert snap["xai_oauth"]["model_ids"] == ["grok-a"]
    refute Map.has_key?(snap["openai_oauth"], "access_token")
    refute Map.has_key?(snap["openai_oauth"], "account_id")
  end

  test "last-good preservation: rejected and malformed puts leave prior catalog" do
    assert {:ok, good} = catalog("openai_oauth", "openai", ["keep-me"], 3)
    assert :ok = ProviderModelCatalogStore.put_sync(good)
    assert {:ok, %ProviderModelCatalog{model_ids: ["keep-me"]}} =
             ProviderModelCatalogStore.fetch_sync("openai_oauth")

    # Alias / non-exact route identity
    assert {:error, :rejected} =
             ProviderModelCatalogStore.put_sync(%{
               route: "openai",
               backend: "openai",
               runtime: "arbor",
               model_ids: ["bad"],
               observed_at: @observed,
               expires_at: @expires,
               credential_generation: 9
             })

    # Route/backend/runtime mismatch
    assert {:error, :rejected} =
             ProviderModelCatalogStore.put_sync(%{
               route: "openai_oauth",
               backend: "xai",
               runtime: "arbor",
               model_ids: ["bad"],
               observed_at: @observed,
               expires_at: @expires,
               credential_generation: 9
             })

    # Malformed attrs
    assert {:error, :rejected} = ProviderModelCatalogStore.put_sync(%{not: "a catalog"})
    assert {:error, :rejected} = ProviderModelCatalogStore.put_sync("not a catalog")
    assert {:error, :rejected} = ProviderModelCatalogStore.put_sync([:improper | :list])

    assert {:ok, kept} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    assert kept.model_ids == ["keep-me"]
    assert kept.credential_generation == 3
  end

  test "empty cache is miss; process unavailability is distinct" do
    assert {:error, :miss} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    assert {:ok, %{}} = ProviderModelCatalogStore.snapshot_sync()

    assert is_pid(Process.whereis(ProviderModelCatalogStore))
    assert :ok = Supervisor.terminate_child(Arbor.AI.Supervisor, ProviderModelCatalogStore)
    assert Process.whereis(ProviderModelCatalogStore) == nil

    try do
      assert {:error, :unavailable} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
      assert {:error, :unavailable} = ProviderModelCatalogStore.snapshot_sync()

      assert {:error, :unavailable} =
               ProviderModelCatalogStore.put_sync(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ["x"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })

      # No caller-owned lazy start while supervised child is terminated.
      assert Process.whereis(ProviderModelCatalogStore) == nil
    after
      ensure_store_running()
    end
  end

  test "restart yields empty cache" do
    assert {:ok, good} = catalog("openai_oauth", "openai", ["volatile"], 1)
    assert :ok = ProviderModelCatalogStore.put_sync(good)
    assert {:ok, _} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)

    pid = Process.whereis(ProviderModelCatalogStore)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    assert :ok = Supervisor.terminate_child(Arbor.AI.Supervisor, ProviderModelCatalogStore)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    ensure_store_running()
    assert {:error, :miss} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    assert {:ok, %{}} = ProviderModelCatalogStore.snapshot_sync()
  end

  test "snapshot is bounded and rejects malformed options" do
    assert {:ok, openai} = catalog("openai_oauth", "openai", ["a"], 1)
    assert :ok = ProviderModelCatalogStore.put_sync(openai)
    assert {:ok, snap} = ProviderModelCatalogStore.snapshot_sync([])
    assert map_size(snap) == 1
    assert is_map(snap["openai_oauth"])

    assert {:error, :malformed} = ProviderModelCatalogStore.snapshot_sync(%{now: @now})
    assert {:error, :malformed} = ProviderModelCatalogStore.snapshot_sync("not-keyword")
  end

  test "malformed stored slot is reported without erasure" do
    assert {:ok, good} = catalog("openai_oauth", "openai", ["still-here"], 4)
    assert :ok = ProviderModelCatalogStore.put_sync(good)

    pid = Process.whereis(ProviderModelCatalogStore)
    assert is_pid(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | routes: %{
            "openai_oauth" => %{
              route: "openai_oauth",
              backend: "openai",
              runtime: "arbor",
              model_ids: ["still-here"],
              observed_at: @observed,
              expires_at: "not-a-timestamp",
              credential_generation: 4
            }
          }
      }
    end)

    try do
      assert Process.alive?(pid)
      assert {:error, :malformed} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
      assert {:error, :malformed} = ProviderModelCatalogStore.snapshot_sync()
      assert Process.alive?(pid)
      assert Process.whereis(ProviderModelCatalogStore) == pid
    after
      # Heal via clear + valid put rather than silent erase.
      :sys.replace_state(pid, fn state -> %{state | routes: %{}} end)
      assert {:error, :miss} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    end
  end

  test "rejects non-OAuth aliases on fetch and clear is exact-route only" do
    assert {:error, :rejected} = ProviderModelCatalogStore.fetch_sync(:openai)
    assert {:error, :rejected} = ProviderModelCatalogStore.fetch_sync("grok")
    assert {:error, :rejected} = ProviderModelCatalogStore.fetch_sync("xai")

    assert {:ok, good} = catalog("openai_oauth", "openai", ["a"], 1)
    assert :ok = ProviderModelCatalogStore.put_sync(good)
    # clear with alias is a no-op
    assert :ok = ProviderModelCatalogStore.clear_sync(:openai)
    assert {:ok, _} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
    assert :ok = ProviderModelCatalogStore.clear_sync(:openai_oauth)
    assert {:error, :miss} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
  end

  test "valid put replaces prior catalog for the same exact route" do
    assert {:ok, first} = catalog("openai_oauth", "openai", ["old"], 1)
    assert {:ok, second} = catalog("openai_oauth", "openai", ["new"], 2)
    assert :ok = ProviderModelCatalogStore.put_sync(first)
    assert :ok = ProviderModelCatalogStore.put_sync(second)
    assert {:ok, got} = ProviderModelCatalogStore.fetch_sync("openai_oauth")
    assert got.model_ids == ["new"]
    assert got.credential_generation == 2
  end

  test "put waits past former finite timeout when store is suspended (infinity call)" do
    # Behavioral lock: mutating put uses :infinity. Suspend past the old 1s
    # timeout, resume, and the caller still receives :ok (not :unavailable)
    # with the catalog committed — reply and commit stay coupled.
    pid = Process.whereis(ProviderModelCatalogStore)
    assert is_pid(pid)

    assert {:ok, entry} = catalog("openai_oauth", "openai", ["after-suspend"], 11)
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    task =
      Task.async(fn ->
        ProviderModelCatalogStore.put_sync(entry)
      end)

    try do
      # Still blocked after the former finite timeout window.
      assert Task.yield(task, @former_finite_timeout_ms + 100) == nil

      :ok = :sys.resume(pid)

      assert :ok = Task.await(task, 500)
      assert {:ok, got} = ProviderModelCatalogStore.fetch_sync(:openai_oauth)
      assert got.model_ids == ["after-suspend"]
      assert got.credential_generation == 11
    after
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp catalog(route, backend, model_ids, generation) do
    ProviderModelCatalog.new(%{
      route: route,
      backend: backend,
      runtime: "arbor",
      model_ids: model_ids,
      observed_at: @observed,
      expires_at: @expires,
      credential_generation: generation
    })
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
