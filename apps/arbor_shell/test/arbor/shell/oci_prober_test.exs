defmodule Arbor.Shell.OciProberTest do
  @moduledoc """
  Hermetic tests for the OCI/Podman admission prober.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.OciProber, as: Prober

  @moduletag :fast

  @digest_hex String.duplicate("a", 64)
  @digest "sha256:#{@digest_hex}"
  @image_id "sha256:" <> String.duplicate("1", 64)
  @lock String.duplicate("c", 64)
  @tree String.duplicate("d", 64)
  @podman "/usr/bin/podman"

  @labels %{
    "org.arbor.validation.schema" => "1",
    "org.arbor.validation.role" => "spawn-containment",
    "org.arbor.validation.platform" => "linux/amd64",
    "org.arbor.validation.erlang" => "28.4.1",
    "org.arbor.validation.elixir" => "1.19.5-otp-28",
    "org.arbor.validation.mix-lock-sha256" => @lock,
    "org.arbor.validation.deps-tree-sha256" => @tree
  }

  defmodule FakeRuntime do
    @moduledoc false

    alias Arbor.Shell.ExecutablePolicy.Executable

    def reset do
      :persistent_term.put({__MODULE__, :mono}, 1_000_000)
      :persistent_term.put({__MODULE__, :mode}, :ok)
      :persistent_term.put({__MODULE__, :resolve_mode}, :ok)
      :persistent_term.put({__MODULE__, :verify_mode}, :ok)
      :persistent_term.put({__MODULE__, :policy_mode}, :ok)
      :persistent_term.put({__MODULE__, :plan_mode}, :ok)
      :persistent_term.put({__MODULE__, :callback_mode}, :ok)
      :persistent_term.put({__MODULE__, :executables}, %{})
      :persistent_term.put({__MODULE__, :policy}, nil)
      :persistent_term.put({__MODULE__, :plan}, nil)
      :persistent_term.put({__MODULE__, :inspect_json}, nil)
      :persistent_term.put({__MODULE__, :arch}, "x86_64-pc-linux-gnu")
      :persistent_term.put({__MODULE__, :runs}, [])
      :persistent_term.put({__MODULE__, :resolves}, [])
      :persistent_term.put({__MODULE__, :host_env_mode}, :ok)
    end

    def set_executables(map), do: :persistent_term.put({__MODULE__, :executables}, map)
    def set_policy(policy), do: :persistent_term.put({__MODULE__, :policy}, policy)
    def set_plan(plan), do: :persistent_term.put({__MODULE__, :plan}, plan)
    def set_inspect_json(json), do: :persistent_term.put({__MODULE__, :inspect_json}, json)
    def set_arch(arch), do: :persistent_term.put({__MODULE__, :arch}, arch)
    def set_resolve_mode(mode), do: :persistent_term.put({__MODULE__, :resolve_mode}, mode)
    def set_verify_mode(mode), do: :persistent_term.put({__MODULE__, :verify_mode}, mode)
    def set_callback_mode(mode), do: :persistent_term.put({__MODULE__, :callback_mode}, mode)
    def runs, do: :persistent_term.get({__MODULE__, :runs}, [])
    def resolves, do: :persistent_term.get({__MODULE__, :resolves}, [])

    def monotonic_ms, do: :persistent_term.get({__MODULE__, :mono}, 1_000_000)
    def system_architecture, do: :persistent_term.get({__MODULE__, :arch})

    def resolve_executable(path) do
      maybe_callback()
      :persistent_term.put({__MODULE__, :resolves}, resolves() ++ [path])

      case :persistent_term.get({__MODULE__, :resolve_mode}, :ok) do
        :ok ->
          case Map.fetch(:persistent_term.get({__MODULE__, :executables}, %{}), path) do
            {:ok, %Executable{} = exe} -> {:ok, exe}
            :error -> {:error, :executable_not_found}
          end

        :untrusted_path ->
          {:error, :untrusted_path}

        :wrong_path ->
          {:ok,
           %Executable{
             name: "podman",
             path: "/home/user/.local/bin/podman",
             device: 1,
             inode: 2,
             size: 3,
             mtime: 0,
             ctime: 0,
             mode: 0o755,
             sha256: String.duplicate("e", 64)
           }}

        other ->
          other
      end
    end

    def verify_executable(%Executable{}) do
      case :persistent_term.get({__MODULE__, :verify_mode}, :ok) do
        :ok -> :ok
        :untrusted_path -> {:error, :untrusted_path}
        other -> other
      end
    end

    def run_bound(%Executable{} = exe, args, opts) do
      maybe_callback()

      :persistent_term.put(
        {__MODULE__, :runs},
        runs() ++ [%{path: exe.path, args: args, opts: opts}]
      )

      json = :persistent_term.get({__MODULE__, :inspect_json})

      {:ok,
       %{
         exit_code: 0,
         stdout: json || "",
         stderr: "",
         duration_ms: 1,
         timed_out: false,
         killed: false,
         output_truncated: false,
         output_limit_exceeded: false
       }}
    end

    def checkout_image_policy do
      maybe_callback()
      {:ok, :persistent_term.get({__MODULE__, :policy})}
    end

    def checkout_baseline_plan do
      maybe_callback()
      {:ok, :persistent_term.get({__MODULE__, :plan})}
    end

    def execution_digest(policy) when is_map(policy) do
      Arbor.Shell.OciProbeRuntime.execution_digest(policy)
    end

    def rootless_host_env do
      case :persistent_term.get({__MODULE__, :host_env_mode}, :ok) do
        :ok ->
          {:ok, closed_host_env()}

        :untrusted_home ->
          {:error, :untrusted_home}

        :extra_keys ->
          {:ok, Map.put(closed_host_env(), "SECRET", "1")}

        other ->
          other
      end
    end

    def closed_host_env do
      %{
        "HOME" => "/home/operator",
        "XDG_RUNTIME_DIR" => "/run/user/1000",
        "PATH" => "/usr/bin:/bin"
      }
    end

    def set_host_env_mode(mode), do: :persistent_term.put({__MODULE__, :host_env_mode}, mode)

    defp maybe_callback do
      case :persistent_term.get({__MODULE__, :callback_mode}, :ok) do
        :ok -> :ok
        :raise -> raise "sentinel-oci-probe-raise"
        :throw -> throw(:sentinel_oci_probe_throw)
        :exit -> exit(:sentinel_oci_probe_exit)
      end
    end
  end

  setup do
    FakeRuntime.reset()
    FakeRuntime.set_executables(%{@podman => fake_podman()})
    FakeRuntime.set_policy(valid_policy())
    FakeRuntime.set_plan(valid_plan())
    FakeRuntime.set_inspect_json(inspect_json())
    :ok
  end

  describe "positive probe" do
    test "returns a JSON-clean admitted envelope for execution" do
      assert {:ok, admission} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert admission["admitted"] == true
      assert admission["runtime"] == %{"path" => @podman}
      assert admission["image"]["execution_reference"] == @digest
      assert admission["image"]["platform"] == "linux/amd64"
      assert admission["platform"] == %{"os" => "linux", "architecture" => "x86_64"}
      refute Map.has_key?(admission, "vminit")
      refute Map.has_key?(admission, "control_plane")
      assert Jason.encode!(admission)

      [run] = FakeRuntime.runs()
      assert run.path == @podman
      assert run.args == ["image", "inspect", @digest]
      assert run.opts[:clear_env] == true
      assert run.opts[:env] == FakeRuntime.closed_host_env()

      assert Map.keys(run.opts[:env]) |> Enum.sort() ==
               ["HOME", "PATH", "XDG_RUNTIME_DIR"]
    end

    test "inspects a locally built image by id and still binds Digest and labels" do
      FakeRuntime.set_policy(Map.put(valid_policy(), :image_id, @image_id))
      FakeRuntime.set_inspect_json(inspect_json(%{"Id" => @image_id}))

      assert {:ok, admission} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert admission["image"]["execution_reference"] == @image_id

      [run] = FakeRuntime.runs()
      assert run.args == ["image", "inspect", @image_id]
    end

    test "maps arm64 hosts to linux/arm64" do
      FakeRuntime.set_arch("aarch64-unknown-linux-gnu")
      labels = Map.put(@labels, "org.arbor.validation.platform", "linux/arm64")
      FakeRuntime.set_policy(Map.put(valid_policy(), :labels, labels))

      inspect =
        inspect_json()
        |> Jason.decode!()
        |> hd()
        |> Map.put("Architecture", "arm64")
        |> Map.put("Labels", labels)
        |> List.wrap()
        |> Jason.encode!()

      FakeRuntime.set_inspect_json(inspect)

      assert {:ok, admission} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert admission["image"]["platform"] == "linux/arm64"
      assert admission["platform"]["architecture"] == "arm64"
    end
  end

  describe "security regression: CLI identity" do
    @tag :security_regression
    test "security regression: non-root-owned CLI identity is rejected" do
      FakeRuntime.set_resolve_mode(:untrusted_path)

      assert {:error, :untrusted_path} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert FakeRuntime.runs() == []
    end

    @tag :security_regression
    test "security regression: user-local podman path is rejected" do
      FakeRuntime.set_resolve_mode(:wrong_path)

      assert {:error, :untrusted_path} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert FakeRuntime.runs() == []
    end

    @tag :security_regression
    test "security regression: caller extra host-env keys are refused" do
      FakeRuntime.set_host_env_mode(:extra_keys)

      assert {:error, :invalid_rootless_host_env} =
               Prober.probe_for_test(5_000, runtime: FakeRuntime)

      assert FakeRuntime.runs() == []
    end

    @tag :security_regression
    test "security regression: HOME that fails the operator pin is refused" do
      FakeRuntime.set_host_env_mode(:untrusted_home)

      assert {:error, :untrusted_home} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      assert FakeRuntime.runs() == []
    end

    @tag :security_regression
    test "security regression: image_id cannot skip inspect digest mismatch" do
      FakeRuntime.set_policy(Map.put(valid_policy(), :image_id, @image_id))

      FakeRuntime.set_inspect_json(
        inspect_json(%{
          "Id" => @image_id,
          "Digest" => "sha256:" <> String.duplicate("f", 64)
        })
      )

      assert {:error, :execution_digest_mismatch} =
               Prober.probe_for_test(5_000, runtime: FakeRuntime)
    end
  end

  describe "failures" do
    test "invalid deadline is rejected" do
      assert {:error, :invalid_probe_deadline} = Prober.probe(0)
      assert {:error, :invalid_probe_deadline} = Prober.probe_for_test(-1, runtime: FakeRuntime)
    end

    test "throw, exit, and raise become probe_failed" do
      for mode <- [:raise, :throw, :exit] do
        FakeRuntime.reset()
        FakeRuntime.set_executables(%{@podman => fake_podman()})
        FakeRuntime.set_callback_mode(mode)

        assert {:error, :probe_failed} = Prober.probe_for_test(5_000, runtime: FakeRuntime)
      end
    end
  end

  defp fake_podman do
    %Executable{
      name: "podman",
      path: @podman,
      device: 1,
      inode: 2,
      size: 100,
      mtime: 0,
      ctime: 0,
      mode: 0o755,
      sha256: String.duplicate("ab", 32)
    }
  end

  defp valid_policy do
    %{
      image: "docker.io/arbor/validation@#{@digest}",
      manifest_digest: @digest,
      labels: @labels,
      mix_lock_digest: @lock,
      baseline_tree_digest: @tree,
      toolchain: %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
    }
  end

  defp valid_plan do
    %{
      "kind" => "linux_dependency_baseline",
      "source_root" => "/opt/arbor/baseline",
      "manifest_path" => "/opt/arbor/baseline/manifest.json",
      "receipt" => %{
        "schema" => "1",
        "platform" => "linux/arm64",
        "image_index_digest" => @digest,
        "image_manifest_digest" => @digest,
        "mix_lock_digest" => @lock,
        "baseline_tree_digest" => @tree,
        "toolchain" => %{"erlang" => "28.4.1", "elixir" => "1.19.5-otp-28"},
        "entry_count" => 1,
        "total_bytes" => 16
      },
      "materialization_entries" => [],
      "evidence_only" => true
    }
  end

  defp inspect_json(overrides \\ %{}) do
    resource =
      Map.merge(
        %{
          "Digest" => @digest,
          "Id" => @digest,
          "Architecture" => "amd64",
          "Os" => "linux",
          "Labels" => @labels
        },
        overrides
      )

    Jason.encode!([resource])
  end
end
