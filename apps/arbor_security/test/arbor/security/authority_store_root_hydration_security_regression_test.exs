defmodule Arbor.Security.AuthorityStoreRootHydrationSecurityRegressionTest do
  @moduledoc """
  Exact-parent security regression for P1C-A authority roots and sticky
  hydration poison.

  Parent behavior (must fail on checkout of the exact parent):
  - A default durable JSONFile AuthorityStore with no base_dir expands
    `.arbor/security` via File.cwd!/0, so File.cd!/1 selects the root.
  - After failed durable hydration, put/3 still reaches the backend
    (OverflowBackend.put/3 returns :ok) and a recovering backend can serve
    later list/get.

  Candidate: injects the Config-owned frozen root; failed hydrate poisons
  subsequent authoritative reads and mutations.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile

  defmodule OverflowBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :ok
    def get(_key, opts), do: send(opts[:test_pid], :overflow_get) && {:error, :not_found}
    def delete(_key, _opts), do: :ok
    def list(_opts), do: {:ok, ["a", "b", "c"]}
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule RecoveringBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :ok
    def get(_key, _opts), do: {:error, :not_found}
    def delete(_key, _opts), do: :ok

    def list(opts) do
      Agent.get_and_update(opts[:agent], fn
        :fail -> {{:error, :backend_unavailable}, :ok}
        :ok -> {{:ok, []}, :ok}
      end)
    end

    def durability_class(_opts), do: :process_lifetime
  end

  setup do
    previous_root = Application.get_env(:arbor_security, :authority_state_root)
    previous_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(previous_cwd)
      restore_authority_root_if_exported()
      restore_env(:authority_state_root, previous_root)
    end)

    :ok
  end

  test "security regression: default durable JSONFile AuthorityStore does not follow File.cwd!/0" do
    freeze_root = unique_abs_root("freeze")
    decoy = unique_abs_root("decoy")
    namespace = "cwd-proof"
    key = "cwd-key"
    name = unique_name(:cwd_root)

    Application.put_env(:arbor_security, :authority_state_root, freeze_root)

    if function_exported?(Config, :freeze_authority_root, 0) do
      assert :ok = apply(Config, :freeze_authority_root, [])
    end

    previous_cwd = File.cwd!()
    File.cd!(decoy)

    try do
      start_supervised!(
        {AuthorityStore, name: name, namespace: namespace, backend: JSONFile}
      )

      assert :ok = AuthorityStore.put(key, Record.new(key, %{"v" => 1}), name: name)

      decoy_base = Path.join(decoy, ".arbor/security")

      assert {:error, :not_found} =
               JSONFile.get(key, base_dir: decoy_base, name: namespace)

      assert {:ok, %Record{data: %{"v" => 1}}} =
               JSONFile.get(key, base_dir: freeze_root, name: namespace)
    after
      File.cd!(previous_cwd)
    end
  end

  test "security regression: failed durable hydration poisons subsequent reads and mutations" do
    name = unique_name(:poison_overflow)

    start_supervised!(
      {AuthorityStore,
       name: name, backend: OverflowBackend, backend_opts: [test_pid: self()], hydration_limit: 2}
    )

    assert {:ok,
            %{
              status: :failed,
              loaded_count: 0,
              configured_limit: 2,
              reason: :hydration_limit_exceeded
            }} = AuthorityStore.hydration_status(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.put("k", Record.new("k"), name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get("k", name: name)

    assert {:error, :hydration_unavailable} = AuthorityStore.authoritative_list(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_entries(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.take_hydrated_entries(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_put("k", Record.new("k"), name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_delete("k", name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k"),
               name: name
             )

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_delete("k", Record.new("k"), name: name)

    assert {:ok, %{status: :failed, reason: :hydration_limit_exceeded}} =
             AuthorityStore.hydration_status(name: name)

    refute_received :overflow_get
  end

  test "security regression: failed durable hydration stays poisoned after the backend recovers" do
    name = unique_name(:poison_recover)
    {:ok, agent} = start_supervised({Agent, fn -> :fail end})

    start_supervised!(
      {AuthorityStore,
       name: name, backend: RecoveringBackend, backend_opts: [agent: agent], hydration_limit: 10}
    )

    assert {:ok, %{status: :failed, reason: :backend_unavailable}} =
             AuthorityStore.hydration_status(name: name)

    assert {:error, :hydration_unavailable} = AuthorityStore.authoritative_list(name: name)
    assert {:error, :hydration_unavailable} = AuthorityStore.put("k", Record.new("k"), name: name)

    assert {:ok, %{status: :failed, reason: :backend_unavailable}} =
             AuthorityStore.hydration_status(name: name)
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_abs_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-p1c-a-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    expanded = Path.expand(path)
    on_exit(fn -> remove_tmp_root!(expanded) end)
    expanded
  end

  defp remove_tmp_root!(path) do
    tmp = Path.expand(System.tmp_dir!())
    expanded = Path.expand(path)

    unless String.starts_with?(expanded, tmp <> "/") do
      raise "refusing to remove authority-root fixture outside tmp: #{inspect(expanded)}"
    end

    File.rm_rf!(expanded)
    :ok
  end

  defp restore_authority_root_if_exported do
    if function_exported?(Config, :restore_authority_root, 0) do
      apply(Config, :restore_authority_root, [])
    else
      :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
