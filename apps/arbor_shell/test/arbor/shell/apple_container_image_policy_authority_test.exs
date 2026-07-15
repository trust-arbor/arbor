defmodule Arbor.Shell.AppleContainerImagePolicyAuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerImagePolicyAuthority, as: Authority

  @app :arbor_shell
  @config_key :apple_container_image_policy

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @tree_hex String.duplicate("d", 64)
  @other_hex String.duplicate("e", 64)
  @vminit_index_hex String.duplicate("f0", 32)
  @vminit_manifest_hex String.duplicate("f1", 32)

  @image "docker.io/arbor/validation@sha256:#{@index_hex}"
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"
  @vminit_image "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}"
  @vminit_manifest_digest "sha256:#{@vminit_manifest_hex}"
  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"

  @valid_policy %{
    image: @image,
    manifest_digest: @manifest_digest,
    vminit_image: @vminit_image,
    vminit_manifest_digest: @vminit_manifest_digest,
    env: [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "ARBOR_VALIDATION=1"
    ],
    labels: %{
      "org.arbor.validation.schema" => "1",
      "org.arbor.validation.role" => "spawn-containment",
      "org.arbor.validation.platform" => "linux/arm64",
      "org.arbor.validation.erlang" => @erlang_version,
      "org.arbor.validation.elixir" => @elixir_version,
      "org.arbor.validation.mix-lock-sha256" => @mix_lock_hex,
      "org.arbor.validation.deps-tree-sha256" => @tree_hex
    },
    mix_lock_digest: @mix_lock_hex,
    baseline_tree_digest: @tree_hex,
    toolchain: %{erlang: @erlang_version, elixir: @elixir_version}
  }

  defmodule FakeConfig do
    @moduledoc false

    def reset do
      :persistent_term.put({__MODULE__, :mode}, :ok)
      :persistent_term.put({__MODULE__, :policy}, nil)
      :persistent_term.put({__MODULE__, :calls}, 0)
    end

    def set_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
    def set_policy(policy), do: :persistent_term.put({__MODULE__, :policy}, policy)
    def calls, do: :persistent_term.get({__MODULE__, :calls}, 0)

    def apple_container_image_policy do
      :persistent_term.put({__MODULE__, :calls}, calls() + 1)

      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :ok ->
          policy =
            :persistent_term.get({__MODULE__, :policy}) ||
              Arbor.Shell.AppleContainerImagePolicyAuthorityTest.valid_policy()

          {:ok, policy}

        :absent ->
          {:error, :apple_container_image_policy_config_absent}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "sentinel-image-policy-config-exception:docker.io/arbor/validation"

        :throw ->
          throw({:sentinel_image_policy_config_throw, "docker.io/arbor/validation"})

        :exit ->
          exit({:sentinel_image_policy_config_exit, "docker.io/arbor/validation"})
      end
    end
  end

  defmodule FakeBaselineAuthority do
    @moduledoc false

    def reset do
      :persistent_term.put({__MODULE__, :mode}, :ok)
      :persistent_term.put({__MODULE__, :plan}, nil)
      :persistent_term.put({__MODULE__, :checkout_calls}, 0)
    end

    def set_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
    def set_plan(plan), do: :persistent_term.put({__MODULE__, :plan}, plan)
    def checkout_calls, do: :persistent_term.get({__MODULE__, :checkout_calls}, 0)

    def checkout_plan do
      :persistent_term.put({__MODULE__, :checkout_calls}, checkout_calls() + 1)

      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :ok ->
          plan =
            :persistent_term.get({__MODULE__, :plan}) ||
              Arbor.Shell.AppleContainerImagePolicyAuthorityTest.valid_plan()

          {:ok, plan}

        :unavailable ->
          {:error, :linux_dependency_baseline_unavailable}

        {:error, reason} ->
          {:error, reason}

        :corrupt ->
          {:ok, :not_a_plan}

        :raise ->
          raise "sentinel-baseline-checkout-exception"

        :throw ->
          throw(:sentinel_baseline_checkout_throw)

        :exit ->
          exit(:sentinel_baseline_checkout_exit)

        :drift_receipt ->
          plan =
            (:persistent_term.get({__MODULE__, :plan}) ||
               Arbor.Shell.AppleContainerImagePolicyAuthorityTest.valid_plan())
            |> put_in(["receipt", "mix_lock_digest"], String.duplicate("f", 64))

          {:ok, plan}
      end
    end
  end

  def valid_policy, do: @valid_policy

  def valid_receipt do
    %{
      "schema" => "1",
      "platform" => "linux/arm64",
      "image_index_digest" => @index_digest,
      "image_manifest_digest" => @manifest_digest,
      "mix_lock_digest" => @mix_lock_hex,
      "baseline_tree_digest" => @tree_hex,
      "toolchain" => %{
        "erlang" => @erlang_version,
        "elixir" => @elixir_version
      },
      "entry_count" => 1,
      "total_bytes" => 0
    }
  end

  def valid_plan do
    %{
      "kind" => "linux_dependency_baseline_source",
      "source_root" => "/var/lib/arbor/linux-deps-source",
      "manifest_path" => "/var/lib/arbor/linux-deps-manifest.json",
      "receipt" => valid_receipt(),
      "materialization_entries" => [
        %{
          "path" => "hex/package/1.0.0/hex_metadata.config",
          "sha256" => String.duplicate("1", 64)
        }
      ],
      "evidence_only" => true
    }
  end

  setup do
    previous = Application.get_env(@app, @config_key)
    FakeConfig.reset()
    FakeBaselineAuthority.reset()
    FakeConfig.set_policy(@valid_policy)
    FakeBaselineAuthority.set_plan(valid_plan())

    on_exit(fn ->
      restore_env(previous)
      FakeConfig.reset()
      FakeBaselineAuthority.reset()
    end)

    :ok
  end

  describe "pinning and checkout" do
    test "valid pin reports redacted status and returns configured policy only" do
      {:ok, pid} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      assert Process.alive?(pid)
      assert FakeConfig.calls() == 1
      assert FakeBaselineAuthority.checkout_calls() == 1

      status = Authority.public_status(pid)
      assert status == %{"state" => "pinned", "reason" => nil}
      refute Map.has_key?(status, "policy")
      refute Map.has_key?(status, "receipt")
      refute Map.has_key?(status, "image")
      refute Map.has_key?(status, "digest")
      refute inspect(status) =~ @image
      refute inspect(status) =~ @mix_lock_hex
      refute inspect(status) =~ @tree_hex

      assert {:ok, policy} = Authority.checkout_policy(pid)
      assert policy == @valid_policy
      assert FakeBaselineAuthority.checkout_calls() == 2

      # Pure policy remains JSON-clean.
      assert Jason.encode!(policy)
      assert Jason.encode!(valid_receipt())
    end

    test "missing config stays unavailable and seals no-repin across restart" do
      boot_epoch = make_ref()
      FakeConfig.set_mode(:absent)
      name1 = unique_name()

      {:ok, unavailable} =
        start_authority(
          name: name1,
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(unavailable) == %{
               "state" => "unavailable",
               "reason" => "missing_config"
             }

      assert {:error, :apple_container_image_policy_unavailable} =
               Authority.checkout_policy(unavailable)

      Process.exit(unavailable, :shutdown)
      wait_until_unregistered(name1)

      # Even with valid config now available, sealed unavailable boot epoch remains closed.
      FakeConfig.set_mode(:ok)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_unavailable"

      assert {:error, :apple_container_image_policy_unavailable} =
               Authority.checkout_policy(restarted)
    end

    test "exact same-epoch restart recovers only matching policy+receipt fingerprint" do
      boot_epoch = make_ref()
      name1 = unique_name()

      {:ok, pid} =
        start_authority(
          name: name1,
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert {:ok, policy} = Authority.checkout_policy(pid)
      assert policy.image == @image

      Process.exit(pid, :shutdown)
      wait_until_unregistered(name1)

      name2 = unique_name()

      {:ok, restarted} =
        start_authority(
          name: name2,
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["state"] == "pinned"
      assert {:ok, ^policy} = Authority.checkout_policy(restarted)
    end

    test "changed policy on same boot epoch poisons and stays unavailable" do
      boot_epoch = make_ref()
      name1 = unique_name()

      {:ok, pid} =
        start_authority(
          name: name1,
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert {:ok, _} = Authority.checkout_policy(pid)
      Process.exit(pid, :shutdown)
      wait_until_unregistered(name1)

      # Change only mix_lock while keeping labels consistent enough for config
      # structure; binding still mismatches baseline on restart pin.
      altered =
        @valid_policy
        |> Map.put(:mix_lock_digest, @other_hex)
        |> put_in([:labels, "org.arbor.validation.mix-lock-sha256"], @other_hex)

      FakeConfig.set_policy(altered)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["state"] == "unavailable"
      assert Authority.public_status(restarted)["reason"] == "boot_epoch_poisoned"

      assert {:error, :apple_container_image_policy_unavailable} =
               Authority.checkout_policy(restarted)
    end
  end

  describe "baseline binding failures" do
    test "rejects index digest mismatch with baseline receipt" do
      FakeBaselineAuthority.set_plan(
        put_in(valid_plan(), ["receipt", "image_index_digest"], "sha256:#{@other_hex}")
      )

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      assert Authority.public_status(pid)["state"] == "unavailable"
      assert Authority.public_status(pid)["reason"] == "image_policy_baseline_index_mismatch"
    end

    test "rejects mix_lock, tree, and toolchain mismatches" do
      for {path, value, reason} <- [
            {["receipt", "mix_lock_digest"], @other_hex,
             "image_policy_baseline_mix_lock_mismatch"},
            {["receipt", "baseline_tree_digest"], @other_hex,
             "image_policy_baseline_tree_mismatch"},
            {["receipt", "toolchain", "erlang"], "99.0.0",
             "image_policy_baseline_toolchain_mismatch"}
          ] do
        FakeBaselineAuthority.reset()
        FakeBaselineAuthority.set_plan(put_in(valid_plan(), path, value))

        {:ok, pid} =
          start_authority(
            name: unique_name(),
            config: FakeConfig,
            baseline_authority: FakeBaselineAuthority
          )

        assert Authority.public_status(pid)["reason"] == reason
      end
    end

    test "rejects malformed plan and receipt" do
      FakeBaselineAuthority.set_mode(:corrupt)

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      assert Authority.public_status(pid)["state"] == "unavailable"

      FakeBaselineAuthority.set_mode(:ok)

      bad_plan =
        valid_plan()
        |> Map.put("ready", true)

      FakeBaselineAuthority.set_plan(bad_plan)

      {:ok, pid2} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      assert Authority.public_status(pid2)["reason"] in [
               "unsupported_plan_keys",
               "provisioning_claim_rejected"
             ]
    end
  end

  describe "callback failures and redaction" do
    test "config raise/throw/exit and baseline raise/throw/exit fail closed without leak" do
      for mode <- [:raise, :throw, :exit] do
        FakeConfig.reset()
        FakeConfig.set_policy(@valid_policy)
        FakeConfig.set_mode(mode)
        FakeBaselineAuthority.reset()
        FakeBaselineAuthority.set_plan(valid_plan())

        {:ok, pid} =
          start_authority(
            name: unique_name(),
            config: FakeConfig,
            baseline_authority: FakeBaselineAuthority
          )

        status = Authority.public_status(pid)
        assert status["state"] == "unavailable"
        refute inspect(status) =~ "sentinel"
        refute inspect(status) =~ @image
      end

      for mode <- [:raise, :throw, :exit] do
        FakeConfig.reset()
        FakeConfig.set_policy(@valid_policy)
        FakeConfig.set_mode(:ok)
        FakeBaselineAuthority.reset()
        FakeBaselineAuthority.set_plan(valid_plan())
        FakeBaselineAuthority.set_mode(mode)

        {:ok, pid} =
          start_authority(
            name: unique_name(),
            config: FakeConfig,
            baseline_authority: FakeBaselineAuthority
          )

        status = Authority.public_status(pid)
        assert status["state"] == "unavailable"
        refute inspect(status) =~ "sentinel"
      end
    end

    test "format_status and crash formatting never expose policy or receipt" do
      {:ok, pid} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      {:status, ^pid, {:module, :gen_server}, [_pdict, _sys, parent, dbg, status]} =
        :sys.get_status(pid)

      rendered = inspect({parent, dbg, status}, limit: :infinity)
      refute rendered =~ @image
      refute rendered =~ @mix_lock_hex
      refute rendered =~ @tree_hex
      refute rendered =~ @index_digest
      refute rendered =~ "org.arbor.validation"
    end
  end

  describe "checkout drift" do
    test "baseline receipt drift poisons and terminates the owner" do
      boot_epoch = make_ref()
      name = unique_name()

      {:ok, pid} =
        start_authority(
          name: name,
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      ref = Process.monitor(pid)
      FakeBaselineAuthority.set_mode(:drift_receipt)

      assert {:error, {:apple_container_image_policy_drift, :baseline_receipt_drift}} =
               Authority.checkout_policy(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:apple_container_image_policy_drift, _}}

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority,
          boot_epoch: boot_epoch
        )

      FakeBaselineAuthority.set_mode(:ok)

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_poisoned"

      assert {:error, :apple_container_image_policy_unavailable} =
               Authority.checkout_policy(restarted)
    end

    @tag :security_regression
    test "security regression: caller-nominated policy/receipt cannot be supplied to checkout" do
      {:ok, pid} =
        start_authority(
          name: unique_name(),
          config: FakeConfig,
          baseline_authority: FakeBaselineAuthority
        )

      attacker_policy =
        Map.put(@valid_policy, :image, "docker.io/evil/image@sha256:#{@other_hex}")

      # Public checkout accepts only a GenServer server reference, never policy/receipt.
      assert {:error, :apple_container_image_policy_authority_unavailable} =
               Authority.checkout_policy(attacker_policy)

      assert {:error, :unsupported_apple_container_image_policy_authority_request} =
               GenServer.call(pid, {:checkout_policy, attacker_policy, valid_receipt()})

      assert {:ok, policy} = Authority.checkout_policy(pid)
      assert policy == @valid_policy
      assert policy.image == @image
      refute policy.image =~ "evil"
    end
  end

  describe "production invariants and rest_for_one" do
    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "production child order places image policy after baseline and before materializer" do
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

      assert Enum.at(children, 3) ==
               {Arbor.Shell.AppleContainerImagePolicyAuthority, [boot_epoch: boot_epoch]}

      assert Arbor.Shell.Application.supervisor_options() ==
               [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
    end

    test "security regression: image policy drift restarts later owners only" do
      boot_epoch = make_ref()

      replace_global_authority_stack!(
        config: FakeConfig,
        baseline_authority: FakeBaselineAuthority,
        boot_epoch: boot_epoch
      )

      on_exit(fn ->
        restore_global_authority_stack!()
        Authority.clear_boot_epoch(boot_epoch)
        Arbor.Shell.AppleContainerControlPlaneAuthority.clear_boot_epoch(boot_epoch)
        Arbor.Shell.LinuxDependencyBaselineAuthority.clear_boot_epoch(boot_epoch)
      end)

      policy_before = Process.whereis(Arbor.Shell.ExecutablePolicy)
      apple_before = Process.whereis(Arbor.Shell.AppleContainerControlPlaneAuthority)
      baseline_before = Process.whereis(Arbor.Shell.LinuxDependencyBaselineAuthority)
      image_before = Process.whereis(Authority)

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
      image_ref = Process.monitor(image_before)
      materializer_ref = Process.monitor(materializer_before)
      registry_ref = Process.monitor(registry_before)
      sessions_ref = Process.monitor(sessions_before)

      FakeBaselineAuthority.set_mode(:drift_receipt)

      assert {:error, {:apple_container_image_policy_drift, :baseline_receipt_drift}} =
               Authority.checkout_policy()

      assert_receive {:DOWN, ^image_ref, :process, ^image_before, _reason}
      assert_receive {:DOWN, ^materializer_ref, :process, ^materializer_before, :shutdown}
      assert_receive {:DOWN, ^registry_ref, :process, ^registry_before, :shutdown}
      assert_receive {:DOWN, ^sessions_ref, :process, ^sessions_before, :shutdown}
      assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}

      assert eventually?(fn ->
               new_image = Process.whereis(Authority)

               new_materializer =
                 Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

               new_registry = Process.whereis(Arbor.Shell.ExecutionRegistry)
               new_sessions = Process.whereis(Arbor.Shell.PortSessionSupervisor)

               is_pid(new_image) and new_image != image_before and
                 is_pid(new_materializer) and new_materializer != materializer_before and
                 is_pid(new_registry) and new_registry != registry_before and
                 is_pid(new_sessions) and new_sessions != sessions_before
             end)

      assert Process.whereis(Arbor.Shell.ExecutablePolicy) == policy_before
      assert Process.whereis(Arbor.Shell.AppleContainerControlPlaneAuthority) == apple_before
      assert Process.whereis(Arbor.Shell.LinuxDependencyBaselineAuthority) == baseline_before
      assert Authority.public_status()["reason"] == "boot_epoch_poisoned"
      assert {:error, :apple_container_image_policy_unavailable} = Authority.checkout_policy()
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

  defp wait_until_unregistered(:none), do: :ok

  defp restore_env(nil), do: Application.delete_env(@app, @config_key)
  defp restore_env(value), do: Application.put_env(@app, @config_key, value)

  defp unique_name do
    :"apple_image_policy_authority_#{System.unique_integer([:positive])}"
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: id}) when is_atom(id), do: id
  defp child_module(module) when is_atom(module), do: module

  defp eventually?(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  defp replace_global_authority_stack!(image_opts) do
    remove_global_authority_stack!()

    {:ok, _apple} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.AppleContainerControlPlaneAuthority, []}
      )

    {:ok, _baseline} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.LinuxDependencyBaselineAuthority, []}
      )

    {:ok, _image} =
      Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, image_opts})

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
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.LinuxDependencyBaselineAuthority, []}
      )

    {:ok, _image} =
      Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, []})

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
          Authority,
          Arbor.Shell.LinuxDependencyBaselineAuthority,
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
end
