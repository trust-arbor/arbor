defmodule Arbor.Commands.SafeRecoveryClosure.PeerRunnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryClosure.PeerRunner

  @moduletag :slow
  @moduletag timeout: 180_000

  test "peer starts a fixture app, injects RELEASE_COOKIE, and shuts down bounded" do
    root = fixture_release!()
    on_exit(fn -> File.rm_rf!(root) end)

    original_authority_root = Application.fetch_env(:arbor_security, :authority_state_root)

    assert {:ok, sample} =
             PeerRunner.__test_measure__(root, ["e0b3_fixture"], self())

    assert_receive {:safe_recovery_authority_root_created, authority_root}, 10_000

    assert sample["observations"]["cookie_set"] == true
    assert sample["observations"]["authority_root_configured"] == true
    assert sample["observations"]["sys_config"] == "applied"
    assert sample["observations"]["start_failures"] == []
    assert Path.type(authority_root) == :absolute
    refute File.exists?(authority_root)

    assert Application.fetch_env(:arbor_security, :authority_state_root) ==
             original_authority_root

    refute Map.has_key?(sample, "cookie")
    refute inspect(sample) =~ "RELEASE_COOKIE="
    refute inspect(sample) =~ authority_root

    names = Enum.map(sample["post_start"]["applications"], & &1["name"])
    assert "e0b3_fixture" in names
    refute "arbor_commands" in names

    assert sample["shutdown"]["status"] == "bounded"
    assert sample["shutdown"]["remaining_names"] == []
    refute "e0b3_fixture" in Enum.map(sample["pre_start"]["applications"], & &1["name"])
  end

  test "security regression: current arbor_security starts in the real peer with an ephemeral root" do
    root = fixture_release!(include_security_apps?: true)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, sample} =
             PeerRunner.__test_measure__(root, ["arbor_security"], self())

    assert_receive {:safe_recovery_authority_root_created, authority_root}

    assert sample["observations"]["start_failures"] == []
    assert sample["observations"]["authority_root_configured"] == true
    assert "arbor_security" in Enum.map(sample["post_start"]["applications"], & &1["name"])
    refute inspect(sample) =~ "authority_root_unconfigured"
    refute inspect(sample) =~ authority_root
    refute File.exists?(authority_root)
  end

  test "peer work failure still removes its exact ephemeral authority root" do
    root = fixture_release!()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, reason} =
             PeerRunner.__test_measure__(root, ["not_a_selected_application"], self())

    assert_receive {:safe_recovery_authority_root_created, authority_root}
    refute File.exists?(authority_root)
    refute inspect(reason) =~ authority_root
  end

  test "real peer rejects missing and malformed ephemeral authority roots without disclosure" do
    root = fixture_release!()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:peer_measure_failed, :ephemeral_authority_root_missing}} =
             PeerRunner.__test_authority_root_validation__(root, :missing)

    assert {:error, {:peer_measure_failed, :ephemeral_authority_root_unsafe}} =
             PeerRunner.__test_authority_root_validation__(root, :wrong_prefix)
  end

  test "security regression: measuring caller death still removes the exact authority root" do
    release_root = fixture_release!()
    on_exit(fn -> File.rm_rf!(release_root) end)
    observer = self()

    {caller, caller_mon} =
      spawn_monitor(fn ->
        PeerRunner.__test_measure__(release_root, ["e0b3_fixture"], observer)
      end)

    assert_receive {:safe_recovery_authority_root_created, authority_root}, 10_000
    assert_receive {:safe_recovery_peer_control_started, control}, 10_000
    control_mon = Process.monitor(control)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_mon, :process, ^caller, :killed}, 10_000
    assert_receive {:DOWN, ^control_mon, :process, ^control, _reason}, 10_000
    assert_eventually_removed(authority_root)
  end

  test "authority-root identity replacement makes cleanup fail closed without path disclosure" do
    release_root = fixture_release!()
    on_exit(fn -> File.rm_rf!(release_root) end)
    observer = self()

    task =
      Task.async(fn ->
        PeerRunner.__test_measure__(release_root, ["e0b3_fixture"], observer)
      end)

    assert_receive {:safe_recovery_authority_root_created, authority_root}, 10_000
    retained_root = authority_root <> ".retained"

    on_exit(fn ->
      File.rm_rf!(authority_root)
      File.rm_rf!(retained_root)
    end)

    File.rename!(authority_root, retained_root)
    File.mkdir!(authority_root)
    File.chmod!(authority_root, 0o700)

    assert {:error, :authority_root_cleanup_failed} = Task.await(task, 120_000)
  end

  test "production surface has no caller-selectable authority-root input" do
    assert function_exported?(PeerRunner, :measure, 1)
    refute function_exported?(PeerRunner, :measure, 2)
    refute function_exported?(PeerRunner, :measure, 3)
  end

  test "layout rejects a cookie before any peer starts" do
    root = fixture_release!()
    File.mkdir_p!(Path.join(root, "releases"))
    File.write!(Path.join(root, "releases/COOKIE"), "secret\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :cookie_present} = PeerRunner.measure(root)
  end

  defp fixture_release!(opts \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "e0b3-peer-#{System.unique_integer([:positive, :monotonic])}"
      )

    ebin = Path.join(root, "lib/e0b3_fixture-0.1.0/ebin")
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "e0b3_fixture.app"),
      """
      {application, e0b3_fixture, [
        {description, "e0b3 fixture"},
        {vsn, "0.1.0"},
        {modules, ['Elixir.E0B3Fixture']},
        {registered, []},
        {applications, [kernel, stdlib]}
      ]}.
      """
    )

    [{E0B3Fixture, bin}] =
      Code.compile_string("""
      defmodule E0B3Fixture do
        def hello, do: :ok
      end
      """)

    File.write!(Path.join(ebin, "Elixir.E0B3Fixture.beam"), bin)

    application_roots =
      if Keyword.get(opts, :include_security_apps?, false) do
        [:arbor_kernel_runtime, :arbor_security]
      else
        [:arbor_kernel_runtime]
      end

    copy_application_deps!(root, application_roots)

    release_dir = Path.join(root, "releases/0.1.0")
    File.mkdir_p!(release_dir)

    File.write!(
      Path.join(release_dir, "sys.config"),
      """
      [
        {kernel, [{logger_level, notice}]},
        {arbor_kernel, [
          {kernel_runtime, [
            {start_profile, full},
            {boot_profile, [
              {manifest_bytes, <<"m">>},
              {signature_bytes, <<"s">>}
            ]}
          ]}
        ]},
        {arbor_security, [
          {start_children, true},
          {storage_backend, 'Elixir.Arbor.Security.Store.JSONFile'},
          {audit_journal_mode, ephemeral},
          {distributed_signals, false}
        ]}
      ].
      """
    )

    root
  end

  defp copy_application_deps!(release_root, roots) do
    roots
    |> Enum.reduce(MapSet.new(), &collect_application_deps!/2)
    |> MapSet.delete(:kernel)
    |> MapSet.delete(:stdlib)
    |> Enum.each(fn app ->
      source = application_ebin!(app)
      destination = Path.join([release_root, "lib", "#{app}-test", "ebin"])
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(source, destination)
    end)
  end

  defp collect_application_deps!(app, seen) do
    if MapSet.member?(seen, app) do
      seen
    else
      case application_properties(app) do
        {:ok, properties} ->
          seen = MapSet.put(seen, app)

          properties
          |> Keyword.get(:applications, [])
          |> Kernel.++(Keyword.get(properties, :included_applications, []))
          |> Enum.reduce(seen, &collect_application_deps!/2)

        :missing ->
          seen
      end
    end
  end

  defp application_properties(app) do
    case :code.lib_dir(app) do
      dir when is_list(dir) ->
        app_file = Path.join([List.to_string(dir), "ebin", "#{app}.app"])
        {:ok, [{:application, ^app, properties}]} = :file.consult(String.to_charlist(app_file))
        {:ok, properties}

      {:error, :bad_name} ->
        :missing
    end
  end

  defp application_ebin!(app) do
    app
    |> :code.lib_dir()
    |> List.to_string()
    |> Path.join("ebin")
  end

  defp assert_eventually_removed(path, attempts \\ 200)

  defp assert_eventually_removed(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      Process.sleep(25)
      assert_eventually_removed(path, attempts - 1)
    else
      refute File.exists?(path)
    end
  end

  defp assert_eventually_removed(path, 0), do: refute(File.exists?(path))
end
