defmodule Arbor.Shell.LinuxDependencyBaselineAuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.LinuxDependencyBaselineAuthority, as: Authority
  alias Arbor.Shell.TrustedPath.Identity

  @app :arbor_shell
  @config_key :linux_dependency_baseline
  @source_root "/var/lib/arbor/linux-deps-source"
  @manifest_path "/var/lib/arbor/linux-deps-manifest.json"
  @sentinel_digest "deadbeefcafebabe0123456789abcdefdeadbeefcafebabe0123456789abcdef"
  @sentinel_inventory_path "hex/package/1.0.0/hex_metadata.config"

  defmodule FakeTrustedPath do
    @moduledoc false

    def reset do
      :persistent_term.put({__MODULE__, :calls}, [])
    end

    def calls do
      :persistent_term.get({__MODULE__, :calls}, [])
    end

    def record(tag) do
      :persistent_term.put({__MODULE__, :calls}, calls() ++ [tag])
      :ok
    end
  end

  defmodule FakeSource do
    @moduledoc false

    alias Arbor.Shell.TrustedPath.Identity

    defmodule Binding do
      @moduledoc false
      defstruct [:source_root, :manifest_path, :digest, :inventory, :token]
    end

    def reset do
      :persistent_term.put({__MODULE__, :pin_attempts}, [])
      :persistent_term.put({__MODULE__, :verify_attempts}, [])
      :persistent_term.put({__MODULE__, :plan_attempts}, [])
      :persistent_term.put({__MODULE__, :pin_mode}, :ok)
      :persistent_term.put({__MODULE__, :verify_mode}, :ok)
      :persistent_term.put({__MODULE__, :plan_mode}, :ok)
      :persistent_term.put({__MODULE__, :binding_token}, "baseline-v1")
    end

    def pin_attempts, do: :persistent_term.get({__MODULE__, :pin_attempts}, [])
    def verify_attempts, do: :persistent_term.get({__MODULE__, :verify_attempts}, [])
    def plan_attempts, do: :persistent_term.get({__MODULE__, :plan_attempts}, [])

    def set_pin_mode(mode), do: :persistent_term.put({__MODULE__, :pin_mode}, mode)
    def set_verify_mode(mode), do: :persistent_term.put({__MODULE__, :verify_mode}, mode)
    def set_plan_mode(mode), do: :persistent_term.put({__MODULE__, :plan_mode}, mode)

    def set_binding_token(token),
      do: :persistent_term.put({__MODULE__, :binding_token}, token)

    def pin(source_root, manifest_path, trusted_path)
        when is_binary(source_root) and is_binary(manifest_path) and is_atom(trusted_path) do
      :persistent_term.put(
        {__MODULE__, :pin_attempts},
        pin_attempts() ++ [{source_root, manifest_path, trusted_path}]
      )

      case :persistent_term.get({__MODULE__, :pin_mode}, :ok) do
        :ok ->
          {:ok, build_binding(source_root, manifest_path)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def pin(_source_root, _manifest_path, _trusted_path), do: {:error, :invalid_locator}

    def verify(%Binding{} = binding, trusted_path) when is_atom(trusted_path) do
      :persistent_term.put(
        {__MODULE__, :verify_attempts},
        verify_attempts() ++ [{binding.token, trusted_path}]
      )

      case :persistent_term.get({__MODULE__, :verify_mode}, :ok) do
        :ok -> :ok
        :drift -> {:error, :identity_mismatch}
        :raise -> raise "sentinel-verify-exception:#{binding.source_root}:#{binding.digest}"
        :throw -> throw({:sentinel_verify_throw, binding.source_root, binding.digest})
        :exit -> exit({:sentinel_verify_exit, binding.source_root, binding.digest})
        {:error, reason} -> {:error, reason}
      end
    end

    def verify(_binding, _trusted_path), do: {:error, :invalid_binding}

    def plan(%Binding{} = binding) do
      :persistent_term.put(
        {__MODULE__, :plan_attempts},
        plan_attempts() ++ [binding.token]
      )

      case :persistent_term.get({__MODULE__, :plan_mode}, :ok) do
        :ok ->
          %{
            "kind" => "linux_dependency_baseline_source",
            "source_root" => binding.source_root,
            "manifest_path" => binding.manifest_path,
            "receipt" => %{
              "digest" => binding.digest,
              "entry_count" => length(binding.inventory)
            },
            "materialization_entries" => binding.inventory,
            "evidence_only" => true
          }

        :corrupt ->
          :not_a_plan

        :raise ->
          raise "sentinel-plan-exception:#{binding.source_root}:#{binding.digest}"

        :throw ->
          throw({:sentinel_plan_throw, binding.source_root, binding.digest})

        :exit ->
          exit({:sentinel_plan_exit, binding.source_root, binding.digest})

        {:error, reason} ->
          {:error, reason}
      end
    end

    def plan(_binding), do: {:error, :invalid_binding}

    def build_binding(source_root, manifest_path) do
      token = :persistent_term.get({__MODULE__, :binding_token}, "baseline-v1")

      %Binding{
        source_root: source_root,
        manifest_path: manifest_path,
        digest: "deadbeefcafebabe0123456789abcdefdeadbeefcafebabe0123456789abcdef",
        inventory: [
          %{
            "path" => "hex/package/1.0.0/hex_metadata.config",
            "sha256" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }
        ],
        token: token
      }
    end

    def identity_fixture(path) do
      %Identity{
        path: path,
        type: :regular,
        device: 1,
        inode: 2,
        size: 10,
        mtime: 1,
        ctime: 1,
        mode: 0o644,
        uid: 0,
        gid: 0,
        sha256: "deadbeefcafebabe0123456789abcdefdeadbeefcafebabe0123456789abcdef",
        executable_required: false
      }
    end
  end

  setup do
    previous = Application.get_env(@app, @config_key)
    FakeSource.reset()
    FakeTrustedPath.reset()

    on_exit(fn ->
      restore_env(previous)
      FakeSource.reset()
      FakeTrustedPath.reset()
    end)

    :ok
  end

  describe "pinning and checkout" do
    test "valid pin reports redacted status and returns evidence-only plan" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath
        )

      assert Process.alive?(pid)
      assert FakeSource.pin_attempts() == [{@source_root, @manifest_path, FakeTrustedPath}]

      status = Authority.public_status(pid)
      assert status == %{"state" => "pinned", "reason" => nil}
      refute Map.has_key?(status, "binding")
      refute Map.has_key?(status, "source_root")
      refute Map.has_key?(status, "manifest_path")
      refute Map.has_key?(status, "inventory")
      refute inspect(status) =~ @source_root
      refute inspect(status) =~ @manifest_path
      refute inspect(status) =~ @sentinel_digest
      refute inspect(status) =~ @sentinel_inventory_path

      assert {:ok, plan} = Authority.checkout_plan(pid)

      assert plan == %{
               "kind" => "linux_dependency_baseline_source",
               "source_root" => @source_root,
               "manifest_path" => @manifest_path,
               "receipt" => %{"digest" => @sentinel_digest, "entry_count" => 1},
               "materialization_entries" => [
                 %{
                   "path" => @sentinel_inventory_path,
                   "sha256" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                 }
               ],
               "evidence_only" => true
             }

      refute Map.has_key?(plan, :source_identity)
      refute Map.has_key?(plan, :manifest_identity)
      refute Map.has_key?(plan, :entry_identities)
      assert FakeSource.verify_attempts() == [{"baseline-v1", FakeTrustedPath}]
      assert FakeSource.plan_attempts() == ["baseline-v1"]
    end

    test "missing config stays unavailable and seals no-repin across restart" do
      boot_epoch = make_ref()
      Application.delete_env(@app, @config_key)

      {:ok, unavailable} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(unavailable) == %{
               "state" => "unavailable",
               "reason" => "missing_config"
             }

      assert {:error, :linux_dependency_baseline_unavailable} =
               Authority.checkout_plan(unavailable)

      assert FakeSource.pin_attempts() == []
      Process.exit(unavailable, :shutdown)
      put_valid_config()

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_unavailable"
      assert FakeSource.pin_attempts() == []
    end

    test "successful same-binding permanent restart matches" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(pid)["state"] == "pinned"
      assert length(FakeSource.pin_attempts()) == 1
      Process.exit(pid, :shutdown)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted) == %{"state" => "pinned", "reason" => nil}
      assert length(FakeSource.pin_attempts()) == 2
      assert {:ok, plan} = Authority.checkout_plan(restarted)
      assert plan["evidence_only"] == true
    end

    test "changed binding on restart poisons without remaining pinned" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(pid)["state"] == "pinned"
      Process.exit(pid, :shutdown)
      FakeSource.set_binding_token("baseline-v2")

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted) == %{
               "state" => "unavailable",
               "reason" => "boot_epoch_poisoned"
             }

      assert {:error, :linux_dependency_baseline_unavailable} =
               Authority.checkout_plan(restarted)
    end

    test "failed repin poisons the boot epoch" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(pid)["state"] == "pinned"
      Process.exit(pid, :shutdown)
      FakeSource.set_pin_mode({:error, :path_not_found})

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_poisoned"
    end

    test "checkout drift poisons before abnormal stop" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      initial_pin_attempts = FakeSource.pin_attempts()
      ref = Process.monitor(pid)
      FakeSource.set_verify_mode(:drift)

      assert {:error, {:linux_dependency_baseline_drift, :identity_mismatch}} =
               Authority.checkout_plan(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:linux_dependency_baseline_drift, :identity_mismatch}}

      FakeSource.set_verify_mode(:ok)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted) == %{
               "state" => "unavailable",
               "reason" => "boot_epoch_poisoned"
             }

      assert FakeSource.pin_attempts() == initial_pin_attempts
    end

    test "poisoned restart performs zero pin work" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      ref = Process.monitor(pid)
      FakeSource.set_verify_mode(:drift)
      assert {:error, {:linux_dependency_baseline_drift, _}} = Authority.checkout_plan(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      pins_before = FakeSource.pin_attempts()
      FakeSource.set_verify_mode(:ok)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_poisoned"
      assert FakeSource.pin_attempts() == pins_before
    end

    test "clear/new epoch permits a fresh baseline" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      ref = Process.monitor(pid)
      FakeSource.set_verify_mode(:drift)
      assert {:error, {:linux_dependency_baseline_drift, _}} = Authority.checkout_plan(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Authority.clear_boot_epoch(boot_epoch)
      FakeSource.set_verify_mode(:ok)
      FakeSource.set_binding_token("baseline-after-clear")

      {:ok, fresh} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(fresh) == %{"state" => "pinned", "reason" => nil}
      assert {:ok, plan} = Authority.checkout_plan(fresh)
      assert plan["evidence_only"] == true
    end

    test "malformed opts fail closed" do
      assert {:error, :invalid_linux_dependency_baseline_authority_name} =
               Authority.start_link(name: self())

      assert {:error, :invalid_linux_dependency_baseline_authority_name} =
               Authority.start_link(name: "not-a-registration-name")

      assert {:error, :duplicate_linux_dependency_baseline_authority_name} =
               Authority.start_link(name: unique_name(), name: unique_name())

      assert {:error, :malformed_linux_dependency_baseline_authority_options} =
               Authority.start_link(%{name: unique_name()})

      put_valid_config()

      assert {:ok, pid} =
               Authority.start_link(
                 name: unique_name(),
                 source: FakeSource,
                 trusted_path: FakeTrustedPath,
                 bindings: %{forged: true},
                 evidence: %{ready: true}
               )

      assert Authority.public_status(pid)["state"] == "unavailable"
      assert FakeSource.pin_attempts() == []
      Process.exit(pid, :shutdown)
    end

    test "security regression: duplicate source/trusted_path/boot_epoch opts fail closed before pin" do
      put_valid_config()
      boot_epoch = make_ref()
      on_exit(fn -> Authority.clear_boot_epoch(boot_epoch) end)

      # Duplicate :source — init stays unavailable; no silent first/last selection.
      assert {:ok, source_dup} =
               start_authority(
                 name: unique_name(),
                 source: FakeSource,
                 source: Arbor.Shell.LinuxDependencyBaselineSource,
                 trusted_path: FakeTrustedPath,
                 boot_epoch: boot_epoch
               )

      assert Authority.public_status(source_dup) == %{
               "state" => "unavailable",
               "reason" => "duplicate_linux_dependency_baseline_authority_source"
             }

      assert FakeSource.pin_attempts() == []

      assert {:ok, trusted_dup} =
               start_authority(
                 name: unique_name(),
                 source: FakeSource,
                 trusted_path: FakeTrustedPath,
                 trusted_path: Arbor.Shell.TrustedPath,
                 boot_epoch: boot_epoch
               )

      assert Authority.public_status(trusted_dup) == %{
               "state" => "unavailable",
               "reason" => "duplicate_linux_dependency_baseline_authority_trusted_path"
             }

      assert FakeSource.pin_attempts() == []

      assert {:ok, epoch_dup} =
               start_authority(
                 name: unique_name(),
                 source: FakeSource,
                 trusted_path: FakeTrustedPath,
                 boot_epoch: boot_epoch,
                 boot_epoch: make_ref()
               )

      assert Authority.public_status(epoch_dup) == %{
               "state" => "unavailable",
               "reason" => "duplicate_linux_dependency_baseline_authority_boot_epoch"
             }

      assert FakeSource.pin_attempts() == []
    end

    test "status and crash formatting omit sentinel path and digest strings" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath
        )

      assert {:ok, plan} = Authority.checkout_plan(pid)
      rendered = pid |> :sys.get_status() |> inspect(limit: :infinity)

      refute rendered =~ @source_root
      refute rendered =~ @manifest_path
      refute rendered =~ @sentinel_digest
      refute rendered =~ @sentinel_inventory_path
      assert rendered =~ "redacted"

      formatted =
        Authority.format_status(%{
          message: {:checkout_plan, plan},
          reason: {:failed, @source_root},
          log: [{:reply, plan}],
          state: %{
            status: :pinned,
            reason: nil,
            binding: FakeSource.build_binding(@source_root, @manifest_path),
            boot_epoch: make_ref()
          }
        })

      assert formatted.message == :redacted
      assert formatted.reason == :redacted
      assert formatted.log == :redacted
      refute inspect(formatted, limit: :infinity) =~ @source_root
      refute inspect(formatted, limit: :infinity) =~ @sentinel_digest
    end

    test "security regression: public_status never exposes binary path/digest reason components" do
      put_valid_config()

      # Pin failure reason carries sentinel path + digest binaries; public_status
      # must collapse them to a generic label instead of interpolating strings.
      FakeSource.set_pin_mode(
        {:error, {:path_not_found, @source_root, @sentinel_digest, @sentinel_inventory_path}}
      )

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath
        )

      status = Authority.public_status(pid)
      assert status["state"] == "unavailable"
      assert status["reason"] == "error_detail"
      refute status["reason"] =~ @source_root
      refute status["reason"] =~ @manifest_path
      refute status["reason"] =~ @sentinel_digest
      refute status["reason"] =~ @sentinel_inventory_path
      refute inspect(status, limit: :infinity) =~ @source_root
      refute inspect(status, limit: :infinity) =~ @sentinel_digest
      refute inspect(status, limit: :infinity) =~ @sentinel_inventory_path
    end

    test "security regression: verify raise/throw/exit poisons epoch without repin" do
      for mode <- [:raise, :throw, :exit] do
        FakeSource.reset()
        put_valid_config()
        boot_epoch = make_ref()

        {:ok, pid} =
          start_authority(
            name: unique_name(),
            source: FakeSource,
            trusted_path: FakeTrustedPath,
            boot_epoch: boot_epoch
          )

        assert Authority.public_status(pid)["state"] == "pinned"
        initial_pins = FakeSource.pin_attempts()
        ref = Process.monitor(pid)
        FakeSource.set_verify_mode(mode)

        assert {:error, {:linux_dependency_baseline_drift, :source_verify_or_plan_failed}} =
                 Authority.checkout_plan(pid)

        assert_receive {:DOWN, ^ref, :process, ^pid,
                        {:linux_dependency_baseline_drift, :source_verify_or_plan_failed}}

        FakeSource.set_verify_mode(:ok)

        {:ok, restarted} =
          start_authority(
            name: unique_name(),
            source: FakeSource,
            trusted_path: FakeTrustedPath,
            boot_epoch: boot_epoch
          )

        assert Authority.public_status(restarted) == %{
                 "state" => "unavailable",
                 "reason" => "boot_epoch_poisoned"
               }

        assert FakeSource.pin_attempts() == initial_pins

        assert {:error, :linux_dependency_baseline_unavailable} =
                 Authority.checkout_plan(restarted)

        Process.exit(restarted, :shutdown)
        Authority.clear_boot_epoch(boot_epoch)
      end
    end

    test "security regression: plan raise/throw/exit/corrupt poisons epoch without repin" do
      for mode <- [:raise, :throw, :exit, :corrupt] do
        FakeSource.reset()
        put_valid_config()
        boot_epoch = make_ref()

        {:ok, pid} =
          start_authority(
            name: unique_name(),
            source: FakeSource,
            trusted_path: FakeTrustedPath,
            boot_epoch: boot_epoch
          )

        assert Authority.public_status(pid)["state"] == "pinned"
        initial_pins = FakeSource.pin_attempts()
        ref = Process.monitor(pid)
        FakeSource.set_plan_mode(mode)

        expected_reason =
          case mode do
            :corrupt -> :invalid_plan
            _corruption -> :source_verify_or_plan_failed
          end

        assert {:error, {:linux_dependency_baseline_drift, ^expected_reason}} =
                 Authority.checkout_plan(pid)

        assert_receive {:DOWN, ^ref, :process, ^pid,
                        {:linux_dependency_baseline_drift, ^expected_reason}}

        down_reason = {:linux_dependency_baseline_drift, expected_reason}
        refute inspect(down_reason) =~ @source_root
        refute inspect(down_reason) =~ @sentinel_digest

        FakeSource.set_plan_mode(:ok)

        {:ok, restarted} =
          start_authority(
            name: unique_name(),
            source: FakeSource,
            trusted_path: FakeTrustedPath,
            boot_epoch: boot_epoch
          )

        assert Authority.public_status(restarted) == %{
                 "state" => "unavailable",
                 "reason" => "boot_epoch_poisoned"
               }

        assert FakeSource.pin_attempts() == initial_pins

        assert {:error, :linux_dependency_baseline_unavailable} =
                 Authority.checkout_plan(restarted)

        Process.exit(restarted, :shutdown)
        Authority.clear_boot_epoch(boot_epoch)
      end
    end

    test "security regression: detail-bearing checkout error reasons are bounded atoms only" do
      put_valid_config()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      initial_pins = FakeSource.pin_attempts()
      ref = Process.monitor(pid)

      FakeSource.set_verify_mode({:error, {:identity_mismatch, @source_root, @sentinel_digest}})

      assert {:error, {:linux_dependency_baseline_drift, :source_verify_or_plan_failed}} =
               Authority.checkout_plan(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:linux_dependency_baseline_drift, :source_verify_or_plan_failed}}

      FakeSource.set_verify_mode(:ok)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          source: FakeSource,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_poisoned"
      assert FakeSource.pin_attempts() == initial_pins
    end
  end

  describe "production invariants and rest_for_one" do
    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "production child order and shared epoch options are exact" do
      boot_epoch = make_ref()
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], boot_epoch)
      modules = Enum.map(children, &child_module/1)

      assert modules == [
               Arbor.Shell.ExecutablePolicy,
               Arbor.Shell.AppleContainerControlPlaneAuthority,
               Arbor.Shell.LinuxDependencyBaselineAuthority,
               Arbor.Shell.AppleContainerImagePolicyAuthority,
               Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
               Arbor.Shell.ExecutionRegistry,
               DynamicSupervisor,
               Arbor.Shell.AppleContainerUnitJournal,
               Arbor.Shell.AppleContainerUnitRecoverySupervisor,
               Arbor.Shell.AppleContainerUnitSupervisor,
               Arbor.Shell.AppleContainerUnitDrainCoordinator
             ]

      assert Enum.at(children, 1) ==
               {Arbor.Shell.AppleContainerControlPlaneAuthority, [boot_epoch: boot_epoch]}

      assert Enum.at(children, 2) ==
               {Arbor.Shell.LinuxDependencyBaselineAuthority, [boot_epoch: boot_epoch]}

      assert Enum.at(children, 3) ==
               {Arbor.Shell.AppleContainerImagePolicyAuthority, [boot_epoch: boot_epoch]}

      materializer_sup = Enum.at(children, 4)

      assert match?(
               %{id: Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor},
               materializer_sup
             )

      assert Arbor.Shell.Application.supervisor_options() ==
               [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
    end

    test "security regression: baseline checkout drift restarts later owners and stays poisoned" do
      put_valid_config()
      boot_epoch = make_ref()

      replace_global_authority_stack!(
        source: FakeSource,
        trusted_path: FakeTrustedPath,
        boot_epoch: boot_epoch
      )

      on_exit(fn ->
        restore_global_authority_stack!()
        Authority.clear_boot_epoch(boot_epoch)
        Arbor.Shell.AppleContainerControlPlaneAuthority.clear_boot_epoch(boot_epoch)
        Arbor.Shell.AppleContainerImagePolicyAuthority.clear_boot_epoch(boot_epoch)
      end)

      policy_before = Process.whereis(Arbor.Shell.ExecutablePolicy)
      apple_before = Process.whereis(Arbor.Shell.AppleContainerControlPlaneAuthority)
      baseline_before = Process.whereis(Authority)
      image_before = Process.whereis(Arbor.Shell.AppleContainerImagePolicyAuthority)

      materializer_before =
        Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

      registry_before = Process.whereis(Arbor.Shell.ExecutionRegistry)
      sessions_before = Process.whereis(Arbor.Shell.PortSessionSupervisor)

      {:ok, session} =
        DynamicSupervisor.start_child(
          Arbor.Shell.PortSessionSupervisor,
          {Task, fn -> Process.sleep(:infinity) end}
        )

      session_ref = Process.monitor(session)
      baseline_ref = Process.monitor(baseline_before)
      image_ref = Process.monitor(image_before)
      materializer_ref = Process.monitor(materializer_before)
      registry_ref = Process.monitor(registry_before)
      sessions_ref = Process.monitor(sessions_before)
      initial_pin_attempts = FakeSource.pin_attempts()

      FakeSource.set_verify_mode(:drift)

      assert {:error, {:linux_dependency_baseline_drift, :identity_mismatch}} =
               Authority.checkout_plan()

      assert_receive {:DOWN, ^baseline_ref, :process, ^baseline_before, _reason}
      assert_receive {:DOWN, ^image_ref, :process, ^image_before, :shutdown}
      assert_receive {:DOWN, ^materializer_ref, :process, ^materializer_before, :shutdown}
      assert_receive {:DOWN, ^registry_ref, :process, ^registry_before, :shutdown}
      assert_receive {:DOWN, ^sessions_ref, :process, ^sessions_before, :shutdown}
      assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}

      assert eventually?(fn ->
               new_baseline = Process.whereis(Authority)
               new_image = Process.whereis(Arbor.Shell.AppleContainerImagePolicyAuthority)

               new_materializer =
                 Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

               new_registry = Process.whereis(Arbor.Shell.ExecutionRegistry)
               new_sessions = Process.whereis(Arbor.Shell.PortSessionSupervisor)

               is_pid(new_baseline) and new_baseline != baseline_before and
                 is_pid(new_image) and new_image != image_before and
                 is_pid(new_materializer) and new_materializer != materializer_before and
                 is_pid(new_registry) and new_registry != registry_before and
                 is_pid(new_sessions) and new_sessions != sessions_before
             end)

      assert Process.whereis(Arbor.Shell.ExecutablePolicy) == policy_before
      assert Process.whereis(Arbor.Shell.AppleContainerControlPlaneAuthority) == apple_before
      assert Authority.public_status()["reason"] == "boot_epoch_poisoned"
      assert {:error, :linux_dependency_baseline_unavailable} = Authority.checkout_plan()
      assert FakeSource.pin_attempts() == initial_pin_attempts
    end
  end

  defp start_authority(opts) do
    name = Keyword.fetch!(opts, :name)

    if boot_epoch = Keyword.get(opts, :boot_epoch) do
      on_exit(fn -> Authority.clear_boot_epoch(boot_epoch) end)
    end

    case Authority.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :shutdown)
          end

          wait_until_unregistered(name)
        end)

        {:ok, pid}

      other ->
        other
    end
  end

  defp wait_until_unregistered(name) when is_atom(name) do
    Enum.reduce_while(1..50, :ok, fn _, acc ->
      case Process.whereis(name) do
        nil ->
          {:halt, acc}

        _pid ->
          Process.sleep(1)
          {:cont, acc}
      end
    end)
  end

  defp put_valid_config do
    Application.put_env(@app, @config_key,
      source_root: @source_root,
      manifest_path: @manifest_path
    )
  end

  defp restore_env(nil), do: Application.delete_env(@app, @config_key)
  defp restore_env(value), do: Application.put_env(@app, @config_key, value)

  defp unique_name do
    :"linux_dep_baseline_authority_#{System.unique_integer([:positive])}"
  end

  defp replace_global_authority_stack!(baseline_opts) do
    remove_global_authority_stack!()

    {:ok, _apple} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.AppleContainerControlPlaneAuthority, []}
      )

    {:ok, _baseline} =
      Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, baseline_opts})

    {:ok, _image} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.AppleContainerImagePolicyAuthority, []}
      )

    {:ok, _materializer} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec()
      )

    {:ok, _registry} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.ExecutionRegistry, []}
      )

    {:ok, _sessions} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )

    {:ok, _journal} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitJournal
      )

    {:ok, _recovery} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitRecoverySupervisor
      )

    {:ok, _units} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitWorker.supervisor_child_spec()
      )

    {:ok, _drain} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitDrainCoordinator
      )

    :ok
  end

  defp restore_global_authority_stack! do
    remove_global_authority_stack!()

    {:ok, _apple} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.AppleContainerControlPlaneAuthority, []}
      )

    {:ok, _baseline} =
      Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, []})

    {:ok, _image} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.AppleContainerImagePolicyAuthority, []}
      )

    {:ok, _materializer} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec()
      )

    {:ok, _registry} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.ExecutionRegistry, []}
      )

    {:ok, _sessions} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )

    {:ok, _journal} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitJournal
      )

    {:ok, _recovery} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitRecoverySupervisor
      )

    {:ok, _units} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitWorker.supervisor_child_spec()
      )

    {:ok, _drain} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.AppleContainerUnitDrainCoordinator
      )

    :ok
  end

  defp remove_global_authority_stack! do
    for child_id <- [
          # Coordinator first so its terminate/2 can drain while UnitSupervisor,
          # recovery, Journal, and PortSession remain live.
          Arbor.Shell.AppleContainerUnitDrainCoordinator,
          Arbor.Shell.AppleContainerUnitSupervisor,
          Arbor.Shell.AppleContainerUnitRecoverySupervisor,
          Arbor.Shell.AppleContainerUnitJournal,
          Arbor.Shell.PortSessionSupervisor,
          Arbor.Shell.ExecutionRegistry,
          Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
          Arbor.Shell.AppleContainerImagePolicyAuthority,
          Authority,
          Arbor.Shell.AppleContainerControlPlaneAuthority
        ] do
      case Supervisor.terminate_child(Arbor.Shell.Supervisor, child_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      case Supervisor.delete_child(Arbor.Shell.Supervisor, child_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    :ok
  end

  defp eventually?(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: module}) when is_atom(module), do: module
  defp child_module(module) when is_atom(module), do: module
end
