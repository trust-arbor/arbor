defmodule Arbor.Security.ConfigAuthorityRootFreezeTest do
  @moduledoc """
  Focused Config tests: Application-owned authority-root freeze has one
  immutable winner; a foreign claim table cannot replace it.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.TestBootstrap

  setup do
    originals = env_snapshot()

    on_exit(fn ->
      Config.restore_authority_root()
      restore_env(originals)
    end)

    :ok
  end

  test "concurrent freeze attempts have one immutable winner" do
    root = unique_abs_root("winner")
    Application.put_env(:arbor_security, :authority_state_root, root)
    Application.delete_env(:arbor_security, JSONFile)

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> Config.freeze_authority_root() end)
      end

    Enum.each(tasks, fn task ->
      assert Task.await(task, 5_000) == :ok
    end)

    other = unique_abs_root("loser")
    Application.put_env(:arbor_security, :authority_state_root, other)
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  end

  test "second freeze does not adopt a later put_env path" do
    root = unique_abs_root("first")
    Application.put_env(:arbor_security, :authority_state_root, root)
    assert :ok = Config.freeze_authority_root()

    Application.put_env(:arbor_security, :authority_state_root, unique_abs_root("second"))
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  end

  test "winner death after ETS insert cannot unfreeze or replace the snapshot" do
    root = unique_abs_root("ets-winner")
    Application.put_env(:arbor_security, :authority_state_root, root)

    previous_seam =
      Application.get_env(:arbor_security, :authority_root_freeze_after_ets_insert_test_seam)

    Application.put_env(:arbor_security, :authority_root_freeze_after_ets_insert_test_seam, %{
      delay_ms: 500,
      notify_pid: self()
    })

    winner = spawn(fn -> Config.freeze_authority_root() end)

    on_exit(fn ->
      if Process.alive?(winner), do: Process.exit(winner, :kill)

      case previous_seam do
        nil ->
          Application.delete_env(
            :arbor_security,
            :authority_root_freeze_after_ets_insert_test_seam
          )

        value ->
          Application.put_env(
            :arbor_security,
            :authority_root_freeze_after_ets_insert_test_seam,
            value
          )
      end
    end)

    assert_receive :authority_root_ets_snapshot_inserted, 1_000
    monitor = Process.monitor(winner)
    Process.exit(winner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^winner, :killed}, 1_000

    assert :persistent_term.get({Config, :authority_root}, :not_frozen) == :not_frozen
    table = claim_table()
    assert [{:claimed, snapshot}] = :ets.lookup(table, :claimed)
    assert %{root: ^root} = snapshot

    Application.put_env(:arbor_security, :authority_state_root, unique_abs_root("after-death"))
    assert {:ok, ^root} = Config.authority_root()
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()

    assert %{root: ^root} = :persistent_term.get({Config, :authority_root}, :not_frozen)
  end

  test "first freezer process exit does not drop the Application-owned claim table" do
    root = unique_abs_root("owned")
    Application.put_env(:arbor_security, :authority_state_root, root)

    freezer =
      Task.async(fn ->
        assert :ok = Config.freeze_authority_root()
        self()
      end)

    freezer_pid = Task.await(freezer, 5_000)
    refute Process.alive?(freezer_pid)

    table = claim_table()
    assert :ets.whereis(table) != :undefined
    owner = :ets.info(table, :owner)
    assert owner == application_start_pid(:arbor_security)
    assert owner != freezer_pid

    Application.put_env(:arbor_security, :authority_state_root, unique_abs_root("after-exit"))
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  end

  test "recreating the claim table rehydrates from persistent_term and does not re-read env" do
    root = unique_abs_root("persist")
    Application.put_env(:arbor_security, :authority_state_root, root)
    assert :ok = Config.freeze_authority_root()

    Application.put_env(:arbor_security, :authority_state_root, unique_abs_root("after-stop"))

    table = claim_table()
    assert :ok = Application.stop(:arbor_security)
    assert :ets.whereis(table) == :undefined

    assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert :ets.whereis(table) != :undefined
    assert :ets.info(table, :owner) == application_start_pid(:arbor_security)
    assert :ets.member(table, :claimed)
    assert {:ok, ^root} = Config.authority_root()
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  after
    restore_security_app()
  end

  test "foreign named claim table fails Application start closed" do
    restore_root = unique_abs_root("foreign-table-restore")
    Application.put_env(:arbor_security, :authority_state_root, restore_root)
    Application.delete_env(:arbor_security, JSONFile)

    table = claim_table()
    assert :ok = Application.stop(:arbor_security)
    assert :ets.whereis(table) == :undefined

    ^table = :ets.new(table, [:named_table, :set, :public])
    foreign_owner = self()
    assert :ets.info(table, :owner) == foreign_owner

    assert {:error, {reason, {Arbor.Security.Application, :start, _args}}} =
             Application.start(:arbor_security)

    assert reason == {:authority_root_claim_table_foreign_owner, foreign_owner}
    refute List.keymember?(Application.started_applications(), :arbor_security, 0)
  after
    restore_security_app()
  end

  test "unconfigured test freeze fails closed without the development default" do
    Application.delete_env(:arbor_security, :authority_state_root)
    Application.delete_env(:arbor_security, JSONFile)
    assert {:error, :authority_root_unconfigured} = Config.freeze_authority_root()
    assert {:error, :authority_root_not_frozen} = Config.authority_root()
  end

  test "relative authority_state_root fails closed in test" do
    Application.put_env(:arbor_security, :authority_state_root, "relative/authority")
    Application.delete_env(:arbor_security, JSONFile)
    assert {:error, :authority_root_not_absolute} = Config.freeze_authority_root()
  end

  test "primary and legacy conflict fails closed" do
    primary = unique_abs_root("primary")
    legacy = unique_abs_root("legacy")
    Application.put_env(:arbor_security, :authority_state_root, primary)
    Application.put_env(:arbor_security, JSONFile, base_dir: legacy)
    assert {:error, :authority_root_conflict} = Config.freeze_authority_root()
  end

  test "equal canonical primary and legacy are one root" do
    root = unique_abs_root("same")
    Application.put_env(:arbor_security, :authority_state_root, root)
    Application.put_env(:arbor_security, JSONFile, base_dir: root)
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  end

  test "legacy JSONFile base_dir is used when primary is absent" do
    root = unique_abs_root("legacy-only")
    Application.delete_env(:arbor_security, :authority_state_root)
    Application.put_env(:arbor_security, JSONFile, base_dir: root)
    assert :ok = Config.freeze_authority_root()
    assert {:ok, ^root} = Config.authority_root()
  end

  test "non-keyword JSONFile env fails closed" do
    Application.delete_env(:arbor_security, :authority_state_root)
    Application.put_env(:arbor_security, JSONFile, :not_a_keyword)
    assert {:error, :authority_root_invalid_legacy} = Config.freeze_authority_root()
  end

  test "authority_store_start_opts frozen root and backend are the final override" do
    snapshot = %{
      start_children: true,
      start_profile: :full,
      backend: JSONFile,
      root: "/frozen/root",
      capabilities_hydration_limit: 10
    }

    opts =
      Config.authority_store_start_opts(:arbor_security_identities, "identities", snapshot,
        backend: :attacker,
        name: :attacker_name,
        namespace: "attacker",
        backend_opts: [base_dir: "/attacker", marker: :kept],
        hydration_limit: 3
      )

    assert opts[:backend] == JSONFile
    assert opts[:name] == :arbor_security_identities
    assert opts[:namespace] == "identities"
    assert opts[:hydration_limit] == 3
    assert opts[:backend_opts][:base_dir] == "/frozen/root"
    assert opts[:backend_opts][:marker] == :kept
  end

  test "authority_store_start_opts does not inject base_dir for a nil backend" do
    snapshot = %{backend: nil, root: "/frozen/root"}

    opts =
      Config.authority_store_start_opts(:arbor_security_issuers, "issuers", snapshot,
        backend_opts: [marker: :kept]
      )

    assert opts[:backend] == nil
    refute Keyword.has_key?(opts[:backend_opts], :base_dir)
    assert opts[:backend_opts][:marker] == :kept
  end

  test "Application activation_only, start_children false, and nil backend do not require freeze" do
    Application.delete_env(:arbor_security, :authority_state_root)
    Application.delete_env(:arbor_security, JSONFile)

    Application.put_env(:arbor_security, :start_children, false)
    Application.put_env(:arbor_security, :storage_backend, JSONFile)
    assert {:ok, %{root: nil}} = Config.startup_store_snapshot(:application)
    assert {:error, :authority_root_not_frozen} = Config.authority_root()

    Application.put_env(:arbor_security, :start_children, true)
    put_kernel_runtime(start_profile: :activation_only)

    assert {:ok, %{root: nil, start_profile: :activation_only}} =
             Config.startup_store_snapshot(:application)

    put_kernel_runtime(start_profile: :full)
    Application.put_env(:arbor_security, :storage_backend, nil)
    assert {:ok, %{root: nil, backend: nil}} = Config.startup_store_snapshot(:application)
  end

  test "TestBootstrap durable JSONFile requires freeze" do
    Application.delete_env(:arbor_security, :authority_state_root)
    Application.delete_env(:arbor_security, JSONFile)
    Application.put_env(:arbor_security, :storage_backend, JSONFile)
    put_kernel_runtime(start_profile: :full)

    assert {:error, :authority_root_unconfigured} =
             Config.startup_store_snapshot(:test_bootstrap)
  end

  test "Application start owns the authority-root claim table" do
    table = claim_table()
    assert :ets.whereis(table) != :undefined
    assert :ets.info(table, :owner) == application_start_pid(:arbor_security)
  end

  test "development default root is compile-time absolute" do
    root = Config.development_authority_root()
    assert Path.type(root) == :absolute
    assert String.ends_with?(root, Path.join(".arbor", "security"))
  end

  defp claim_table, do: Module.concat(Config, AuthorityRootClaim)

  defp application_start_pid(app) do
    master = :application_controller.get_master(app)
    {root_sup, _module} = :application_master.get_child(master)

    root_sup
    |> Process.info(:dictionary)
    |> elem(1)
    |> Keyword.fetch!(:"$ancestors")
    |> hd()
  end

  defp unique_abs_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-p1c-a-cfg-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    expanded = Path.expand(path)
    on_exit(fn -> File.rm_rf!(expanded) end)
    expanded
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp env_snapshot do
    %{
      authority_state_root: Application.get_env(:arbor_security, :authority_state_root),
      json_file: Application.get_env(:arbor_security, JSONFile),
      storage_backend: Application.get_env(:arbor_security, :storage_backend),
      start_children: Application.get_env(:arbor_security, :start_children),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime)
    }
  end

  defp restore_env(originals) do
    restore_security_env(:authority_state_root, originals.authority_state_root)
    restore_json_file_env(originals.json_file)
    restore_security_env(:storage_backend, originals.storage_backend)
    restore_security_env(:start_children, originals.start_children)

    case originals.kernel_runtime do
      {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
      :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
    end
  end

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp restore_json_file_env(nil), do: Application.delete_env(:arbor_security, JSONFile)
  defp restore_json_file_env(value), do: Application.put_env(:arbor_security, JSONFile, value)

  defp restore_security_app do
    table = claim_table()

    if :ets.whereis(table) != :undefined and :ets.info(table, :owner) == self() do
      :ets.delete(table)
    end

    _ = Application.stop(:arbor_security)

    if :ets.whereis(table) != :undefined and :ets.info(table, :owner) == self() do
      :ets.delete(table)
    end

    {:ok, _} = Application.ensure_all_started(:arbor_security)
    ensure_signals_children()
    _ = TestBootstrap.start!()
    :ok
  end

  defp ensure_signals_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {module, _opts} = child
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
  end
end
