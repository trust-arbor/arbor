defmodule Arbor.Shell.AppleContainerProbeRuntimeTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.AppleContainerProbeRuntime, as: Runtime
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @vminit_index_hex String.duplicate("c", 64)
  @vminit_manifest_hex String.duplicate("d", 64)
  @workload_alias "127.0.0.1:0/arbor/workload@sha256:#{@index_hex}"
  @vminit_alias "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_index_hex}"

  @policy %{
    image: "docker.io/arbor/validation@sha256:#{@index_hex}",
    manifest_digest: "sha256:#{@manifest_hex}",
    vminit_image: "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}",
    vminit_manifest_digest: "sha256:#{@vminit_manifest_hex}",
    env: [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "ARBOR_VALIDATION=1"
    ],
    labels: %{
      "org.arbor.validation.schema" => "1",
      "org.arbor.validation.role" => "spawn-containment",
      "org.arbor.validation.platform" => "linux/arm64",
      "org.arbor.validation.erlang" => "28.4.1",
      "org.arbor.validation.elixir" => "1.19.5-otp-28",
      "org.arbor.validation.mix-lock-sha256" => String.duplicate("e", 64),
      "org.arbor.validation.deps-tree-sha256" => String.duplicate("f", 64)
    },
    mix_lock_digest: String.duplicate("e", 64),
    baseline_tree_digest: String.duplicate("f", 64),
    toolchain: %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
  }

  defmodule RefusingAuthority do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def init(opts), do: {:ok, opts}

    def handle_call(:checkout_bindings, _from, state) do
      send(state[:observer], :checked_cli_identity)
      # Exhaust the command's 1ms budget before it could reach the Executor,
      # even if a regression removes the image-policy check under test.
      Process.sleep(5)
      {:reply, {:ok, %{cli_identity: state[:identity]}}, state}
    end

    def handle_call(:checkout_policy, _from, state) do
      send(state[:observer], :checked_image_policy)
      {:reply, {:error, :apple_container_image_policy_unavailable}, state}
    end
  end

  describe "closed Apple Container probe command policy" do
    test "each image inspect rechecks CLI identity and image policy at the effect boundary" do
      executable = invalid_container_executable()

      identity =
        struct!(
          Identity,
          executable
          |> Map.from_struct()
          |> Map.delete(:name)
          |> Map.merge(%{type: :regular, uid: 0, gid: 0, executable_required: true})
        )

      # Replace only these test-VM owners. The real Runtime API still resolves
      # fixed authority names; no production injection seam is added.
      authorities = [
        Arbor.Shell.AppleContainerControlPlaneAuthority,
        Arbor.Shell.AppleContainerImagePolicyAuthority
      ]

      for authority <- authorities do
        :ok = Supervisor.terminate_child(Arbor.Shell.Supervisor, authority)

        start_supervised!(
          Supervisor.child_spec(
            {RefusingAuthority, name: authority, observer: self(), identity: identity},
            id: authority
          )
        )
      end

      on_exit(fn ->
        for authority <- authorities do
          {:ok, _pid} = Supervisor.restart_child(Arbor.Shell.Supervisor, authority)
        end
      end)

      for reference <- [@workload_alias, @vminit_alias] do
        assert {:error, :apple_container_image_policy_unavailable} =
                 Runtime.run_bound(executable, ["image", "inspect", reference],
                   cwd: "/",
                   clear_env: true,
                   timeout: 1,
                   max_output_bytes: 8_192
                 )

        assert_receive :checked_cli_identity
        assert_receive :checked_image_policy
        refute_received :checked_cli_identity
        refute_received :checked_image_policy
      end
    end

    test "accepts only the reviewed system JSON probes and policy-derived aliases" do
      assert :ok =
               Runtime.authorize_container_probe_args(
                 ["system", "version", "--format", "json"],
                 @policy
               )

      assert :ok =
               Runtime.authorize_container_probe_args(
                 ["system", "status", "--format", "json"],
                 @policy
               )

      assert :ok =
               Runtime.authorize_container_probe_args(
                 ["image", "inspect", @workload_alias],
                 @policy
               )

      assert :ok =
               Runtime.authorize_container_probe_args(
                 ["image", "inspect", @vminit_alias],
                 @policy
               )
    end

    test "security regression: unreviewed argv is rejected before execution" do
      executable = invalid_container_executable()

      assert {:error, :unreviewed_apple_container_probe_command} =
               Runtime.run_bound(executable, ["system", "start"], valid_opts())

      assert {:error, :unreviewed_apple_container_probe_command} =
               Runtime.run_bound(executable, ["image", "rm", @workload_alias], valid_opts())
    end

    test "security regression: inspect accepts only the two exact immutable policy aliases" do
      changed_digest =
        "127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("0", 64)}"

      for reference <- [
            "docker.io/arbor/validation@sha256:#{@index_hex}",
            "127.0.0.1:0/arbor/other@sha256:#{@index_hex}",
            changed_digest,
            @workload_alias <> ":latest"
          ] do
        assert {:error, :unreviewed_apple_container_probe_command} =
                 Runtime.authorize_container_probe_args(
                   ["image", "inspect", reference],
                   @policy
                 )
      end
    end

    test "rejects option injection and command-specific output bound expansion before execution" do
      executable = invalid_container_executable()

      assert {:error, :invalid_apple_container_probe_options} =
               Runtime.run_bound(
                 executable,
                 ["system", "status", "--format", "json"],
                 valid_opts() ++ [allow_fork: true]
               )

      assert {:error, :invalid_apple_container_probe_options} =
               Runtime.run_bound(
                 executable,
                 ["system", "status", "--format", "json"],
                 Keyword.put(valid_opts(), :max_output_bytes, 8_193)
               )
    end
  end

  defp valid_opts do
    [cwd: "/", clear_env: true, timeout: 5_000, max_output_bytes: 8_192]
  end

  defp invalid_container_executable do
    %Executable{
      name: "container",
      path: "/usr/local/bin/container",
      device: 0,
      inode: 0,
      size: 0,
      mtime: 0,
      ctime: 0,
      mode: 0o100755,
      sha256: String.duplicate("0", 64)
    }
  end
end
