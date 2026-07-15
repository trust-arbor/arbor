defmodule Arbor.Shell.AppleContainerProberTest do
  @moduledoc """
  Focused tests for the internal Apple Container admission prober.

  Uses a same-library fake runtime only. Never executes real container/codesign
  commands or mutates Application config.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.AppleContainerProber, as: Prober
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @tree_hex String.duplicate("d", 64)
  @vminit_index_hex String.duplicate("f0", 32)
  @vminit_manifest_hex String.duplicate("f1", 32)
  @cli_sha String.duplicate("ab", 32)
  @api_sha String.duplicate("cd", 32)
  @plugin_sha String.duplicate("ef", 32)
  @config_sha String.duplicate("a1", 32)
  @kernel_sha String.duplicate("b2", 32)

  @image "docker.io/arbor/validation@sha256:#{@index_hex}"
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"
  @vminit_image "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}"
  @vminit_manifest_digest "sha256:#{@vminit_manifest_hex}"
  @workload_alias "127.0.0.1:0/arbor/workload@#{@index_digest}"
  @vminit_alias "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_index_hex}"

  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"
  @app_root "/Users/arbor/Library/Application Support/com.apple.container"
  @exec_mode 0o100755
  @file_mode 0o100644
  @env [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "ARBOR_VALIDATION=1"
  ]

  @labels %{
    "org.arbor.validation.schema" => "1",
    "org.arbor.validation.role" => "spawn-containment",
    "org.arbor.validation.platform" => "linux/arm64",
    "org.arbor.validation.erlang" => @erlang_version,
    "org.arbor.validation.elixir" => @elixir_version,
    "org.arbor.validation.mix-lock-sha256" => @mix_lock_hex,
    "org.arbor.validation.deps-tree-sha256" => @tree_hex
  }

  @plugin_toml """
  abstract = "Linux container runtime plugin"
  author = "Apple"
  version = 0.1

  [servicesConfig]
  loadAtBoot = false
  runAtLoad = false
  defaultArguments = []

  [[servicesConfig.services]]
  type = "runtime"
  """

  @launchctl_clean """
  gui/501/com.apple.container.apiserver = {
  \tpath = #{@app_root}/apiserver/apiserver.plist
  \ttype = LaunchAgent
  \tstate = running
  \tprogram = /usr/local/bin/container-apiserver
  \targuments = {
  \t\t/usr/local/bin/container-apiserver
  \t\tstart
  \t}
  \tinherited environment = {
  \t\tHOME => /Users/arbor
  \t\tPATH => /usr/bin:/bin
  \t}
  \tdefault environment = {
  \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
  \t}
  \tenvironment = {
  \t\tOSLogRateLimit => 64
  \t\tCONTAINER_INSTALL_ROOT => /usr/local
  \t\tCONTAINER_APP_ROOT => #{@app_root}
  \t\tXPC_SERVICE_NAME => com.apple.container.apiserver
  \t}
  }
  """

  defmodule FakeRuntime do
    @moduledoc false

    alias Arbor.Shell.ExecutablePolicy.Executable
    alias Arbor.Shell.TrustedPath.Identity

    def reset do
      :persistent_term.put({__MODULE__, :mono}, 1_000_000)
      :persistent_term.put({__MODULE__, :events}, [])
      :persistent_term.put({__MODULE__, :resolve_order}, [])
      :persistent_term.put({__MODULE__, :runs}, [])
      :persistent_term.put({__MODULE__, :mode}, :ok)
      :persistent_term.put({__MODULE__, :bindings}, nil)
      :persistent_term.put({__MODULE__, :policy}, nil)
      :persistent_term.put({__MODULE__, :plan}, nil)
      :persistent_term.put({__MODULE__, :plugin_bytes}, nil)
      :persistent_term.put({__MODULE__, :executables}, %{})
      :persistent_term.put({__MODULE__, :run_handler}, nil)
      :persistent_term.put({__MODULE__, :checkout_bindings_mode}, :ok)
      :persistent_term.put({__MODULE__, :checkout_policy_mode}, :ok)
      :persistent_term.put({__MODULE__, :checkout_plan_mode}, :ok)
      :persistent_term.put({__MODULE__, :verify_exec_mode}, :ok)
      :persistent_term.put({__MODULE__, :plugin_mode}, :ok)
      :persistent_term.put({__MODULE__, :user_plugin_mode}, :ok)
      :persistent_term.put({__MODULE__, :callback_mode}, :ok)
      :persistent_term.put({__MODULE__, :bindings_calls}, 0)
      :persistent_term.put({__MODULE__, :policy_calls}, 0)
      :persistent_term.put({__MODULE__, :plan_calls}, 0)
      :persistent_term.put({__MODULE__, :advance_on}, %{})
      :persistent_term.put({__MODULE__, :verify_order}, [])
    end

    def set_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
    def set_bindings(b), do: :persistent_term.put({__MODULE__, :bindings}, b)
    def set_policy(p), do: :persistent_term.put({__MODULE__, :policy}, p)
    def set_plan(p), do: :persistent_term.put({__MODULE__, :plan}, p)
    def set_plugin_bytes(b), do: :persistent_term.put({__MODULE__, :plugin_bytes}, b)
    def set_executables(m), do: :persistent_term.put({__MODULE__, :executables}, m)
    def set_run_handler(fun), do: :persistent_term.put({__MODULE__, :run_handler}, fun)

    def set_checkout_bindings_mode(m),
      do: :persistent_term.put({__MODULE__, :checkout_bindings_mode}, m)

    def set_checkout_policy_mode(m),
      do: :persistent_term.put({__MODULE__, :checkout_policy_mode}, m)

    def set_checkout_plan_mode(m), do: :persistent_term.put({__MODULE__, :checkout_plan_mode}, m)
    def set_verify_exec_mode(m), do: :persistent_term.put({__MODULE__, :verify_exec_mode}, m)
    def set_plugin_mode(m), do: :persistent_term.put({__MODULE__, :plugin_mode}, m)
    def set_user_plugin_mode(m), do: :persistent_term.put({__MODULE__, :user_plugin_mode}, m)
    def set_callback_mode(m), do: :persistent_term.put({__MODULE__, :callback_mode}, m)

    def set_advance_on(op, ms) when is_atom(op) and is_integer(ms) and ms > 0 do
      map = :persistent_term.get({__MODULE__, :advance_on}, %{})
      :persistent_term.put({__MODULE__, :advance_on}, Map.put(map, op, ms))
    end

    def advance_mono(ms), do: :persistent_term.put({__MODULE__, :mono}, monotonic_ms() + ms)

    def events, do: :persistent_term.get({__MODULE__, :events}, [])
    def resolve_order, do: :persistent_term.get({__MODULE__, :resolve_order}, [])
    def runs, do: :persistent_term.get({__MODULE__, :runs}, [])
    def verify_order, do: :persistent_term.get({__MODULE__, :verify_order}, [])

    def monotonic_ms, do: :persistent_term.get({__MODULE__, :mono}, 1_000_000)
    def system_architecture, do: ~c"aarch64-apple-darwin24.0.0"

    def resolve_executable(path) do
      maybe_callback()
      maybe_advance(:resolve_executable)
      log_event({:resolve, path})
      :persistent_term.put({__MODULE__, :resolve_order}, resolve_order() ++ [path])
      exes = :persistent_term.get({__MODULE__, :executables}, %{})

      case Map.fetch(exes, path) do
        {:ok, %Executable{} = exe} -> {:ok, exe}
        :error -> {:error, :executable_not_found}
      end
    end

    def verify_executable(%Executable{} = exe) do
      maybe_advance(:verify_executable)
      log_event({:verify, exe.path})
      :persistent_term.put({__MODULE__, :verify_order}, verify_order() ++ [exe.path])

      case :persistent_term.get({__MODULE__, :verify_exec_mode}, :ok) do
        :ok -> :ok
        :drift -> {:error, :executable_not_pinned}
        other -> other
      end
    end

    def run_bound(%Executable{} = exe, args, opts) do
      maybe_callback()
      maybe_advance(:run_bound)
      log_event({:run, exe.path, args})
      entry = %{path: exe.path, args: args, opts: opts}
      :persistent_term.put({__MODULE__, :runs}, runs() ++ [entry])

      case :persistent_term.get({__MODULE__, :run_handler}, nil) do
        fun when is_function(fun, 3) ->
          fun.(exe, args, opts)

        nil ->
          default_run(exe.path, args)
      end
    end

    def checkout_control_plane_bindings do
      maybe_callback()
      n = :persistent_term.get({__MODULE__, :bindings_calls}, 0) + 1
      :persistent_term.put({__MODULE__, :bindings_calls}, n)
      log_event({:checkout_bindings, n})
      maybe_advance_checkout(:checkout_bindings, n)

      case :persistent_term.get({__MODULE__, :checkout_bindings_mode}, :ok) do
        :ok ->
          {:ok, :persistent_term.get({__MODULE__, :bindings})}

        :ok_then_drift when n == 1 ->
          {:ok, :persistent_term.get({__MODULE__, :bindings})}

        :ok_then_drift when n > 1 ->
          {:ok, Map.put(:persistent_term.get({__MODULE__, :bindings}), :app_root, "/evil")}

        :drift ->
          {:ok, Map.put(:persistent_term.get({__MODULE__, :bindings}), :app_root, "/evil")}

        :error ->
          {:error, :control_plane_unavailable}

        :raise ->
          raise "sentinel-bindings-raise"

        :throw ->
          throw(:sentinel_bindings_throw)

        :exit ->
          exit(:sentinel_bindings_exit)
      end
    end

    def checkout_image_policy do
      maybe_callback()
      n = :persistent_term.get({__MODULE__, :policy_calls}, 0) + 1
      :persistent_term.put({__MODULE__, :policy_calls}, n)
      log_event({:checkout_policy, n})
      maybe_advance_checkout(:checkout_policy, n)

      case :persistent_term.get({__MODULE__, :checkout_policy_mode}, :ok) do
        :ok ->
          {:ok, :persistent_term.get({__MODULE__, :policy})}

        :ok_then_drift when n == 1 ->
          {:ok, :persistent_term.get({__MODULE__, :policy})}

        :ok_then_drift when n > 1 ->
          policy = :persistent_term.get({__MODULE__, :policy})
          {:ok, Map.put(policy, :mix_lock_digest, String.duplicate("f", 64))}

        :drift ->
          policy = :persistent_term.get({__MODULE__, :policy})
          {:ok, Map.put(policy, :mix_lock_digest, String.duplicate("f", 64))}

        :error ->
          {:error, :image_policy_unavailable}
      end
    end

    def checkout_baseline_plan do
      maybe_callback()
      n = :persistent_term.get({__MODULE__, :plan_calls}, 0) + 1
      :persistent_term.put({__MODULE__, :plan_calls}, n)
      log_event({:checkout_plan, n})
      maybe_advance_checkout(:checkout_plan, n)

      case :persistent_term.get({__MODULE__, :checkout_plan_mode}, :ok) do
        :ok ->
          {:ok, :persistent_term.get({__MODULE__, :plan})}

        :ok_then_drift when n == 1 ->
          {:ok, :persistent_term.get({__MODULE__, :plan})}

        :ok_then_drift when n > 1 ->
          plan = :persistent_term.get({__MODULE__, :plan})
          receipt = Map.put(plan["receipt"], "mix_lock_digest", String.duplicate("f", 64))
          {:ok, Map.put(plan, "receipt", receipt)}

        :drift ->
          plan = :persistent_term.get({__MODULE__, :plan})
          receipt = Map.put(plan["receipt"], "mix_lock_digest", String.duplicate("f", 64))
          {:ok, Map.put(plan, "receipt", receipt)}

        :error ->
          {:error, :linux_dependency_baseline_unavailable}
      end
    end

    def verify_identity(%Identity{}), do: :ok
    def verify_identity(_), do: {:error, :invalid_identity}

    def read_plugin_config(%Identity{} = identity) do
      maybe_advance(:read_plugin_config)
      log_event(:read_plugin_config)

      case :persistent_term.get({__MODULE__, :plugin_mode}, :ok) do
        :ok ->
          bytes =
            :persistent_term.get({__MODULE__, :plugin_bytes}) ||
              Arbor.Shell.AppleContainerProberTest.plugin_toml()

          expected =
            :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

          if identity.sha256 == expected do
            {:ok, bytes}
          else
            {:ok, bytes}
          end

        :too_large ->
          {:error, :plugin_config_too_large}

        :hash_mismatch ->
          {:error, :plugin_config_hash_mismatch}

        :identity_drift ->
          {:error, :identity_mismatch}

        :raise ->
          raise "sentinel-plugin-raise"
      end
    end

    def prove_user_plugin_root_absent do
      maybe_advance(:prove_user_plugin_root_absent)
      log_event(:prove_user_plugin_root_absent)

      case :persistent_term.get({__MODULE__, :user_plugin_mode}, :ok) do
        :ok -> :ok
        :present -> {:error, :user_plugin_root_present}
        :error -> {:error, :user_plugin_root_probe_failed}
      end
    end

    defp log_event(event) do
      :persistent_term.put({__MODULE__, :events}, events() ++ [event])
    end

    defp maybe_advance(op) do
      map = :persistent_term.get({__MODULE__, :advance_on}, %{})

      case Map.get(map, op) do
        ms when is_integer(ms) and ms > 0 ->
          advance_mono(ms)
          :ok

        _ ->
          :ok
      end
    end

    defp maybe_advance_checkout(op, n) do
      map = :persistent_term.get({__MODULE__, :advance_on}, %{})

      case Map.get(map, op) do
        {ms, after_n} when is_integer(ms) and is_integer(after_n) and n > after_n ->
          advance_mono(ms)
          :ok

        ms when is_integer(ms) and ms > 0 and n == 1 ->
          # first-call advance only when plain integer configured
          advance_mono(ms)
          :ok

        ms when is_integer(ms) and ms > 0 ->
          :ok

        _ ->
          :ok
      end
    end

    def set_advance_on_after(op, ms, after_calls)
        when is_atom(op) and is_integer(ms) and is_integer(after_calls) do
      map = :persistent_term.get({__MODULE__, :advance_on}, %{})
      :persistent_term.put({__MODULE__, :advance_on}, Map.put(map, op, {ms, after_calls}))
    end

    defp maybe_callback do
      case :persistent_term.get({__MODULE__, :callback_mode}, :ok) do
        :ok -> :ok
        :raise -> raise "sentinel-runtime-raise"
        :throw -> throw(:sentinel_runtime_throw)
        :exit -> exit(:sentinel_runtime_exit)
      end
    end

    defp default_run("/usr/bin/id", ["-u"]), do: ok_out("501\n")
    defp default_run("/usr/bin/sw_vers", ["-productVersion"]), do: ok_out("26.5.2\n")

    defp default_run("/bin/launchctl", ["print", "gui/501/com.apple.container.apiserver"]) do
      ok_out(Arbor.Shell.AppleContainerProberTest.launchctl_clean())
    end

    defp default_run("/usr/local/bin/container", ["system", "version", "--format", "json"]) do
      ok_out(Arbor.Shell.AppleContainerProberTest.system_version_json())
    end

    defp default_run("/usr/local/bin/container", ["system", "status", "--format", "json"]) do
      ok_out(Arbor.Shell.AppleContainerProberTest.system_status_json())
    end

    defp default_run("/usr/local/bin/container", ["image", "inspect", ref]) do
      cond do
        String.contains?(ref, "arbor/workload") ->
          ok_out(Arbor.Shell.AppleContainerProberTest.workload_inspect_json())

        String.contains?(ref, "arbor/vminit") ->
          ok_out(Arbor.Shell.AppleContainerProberTest.vminit_inspect_json())

        true ->
          {:ok, fail_out(1, "")}
      end
    end

    defp default_run("/usr/bin/codesign", args) do
      if Enum.any?(args, &String.starts_with?(&1, "-R=")) do
        ok_out("")
      else
        {:ok, fail_out(1, "")}
      end
    end

    defp default_run(_path, _args), do: {:ok, fail_out(1, "")}

    defp ok_out(stdout) do
      {:ok,
       %{
         exit_code: 0,
         stdout: stdout,
         stderr: "",
         duration_ms: 1,
         timed_out: false,
         killed: false,
         output_truncated: false,
         output_limit_exceeded: false
       }}
    end

    defp fail_out(code, stdout) do
      %{
        exit_code: code,
        stdout: stdout,
        stderr: "",
        duration_ms: 1,
        timed_out: false,
        killed: false,
        output_truncated: false,
        output_limit_exceeded: false
      }
    end
  end

  def plugin_toml, do: @plugin_toml
  def launchctl_clean, do: @launchctl_clean

  def system_version_json do
    Jason.encode!([
      %{
        "appName" => "container",
        "buildType" => "release",
        "commit" => "unspecified",
        "version" => "1.1.0"
      },
      %{
        "appName" => "container-apiserver",
        "buildType" => "release",
        "commit" => "unspecified",
        "version" => "container-apiserver version 1.1.0 (build: release, commit: unspeci)"
      }
    ])
  end

  def system_status_json do
    Jason.encode!(%{
      "apiServerAppName" => "container-apiserver",
      "apiServerBuild" => "release",
      "apiServerCommit" => "unspecified",
      "apiServerVersion" => "container-apiserver version 1.1.0 (build: release, commit: unspeci)",
      "appRoot" => @app_root <> "/",
      "installRoot" => "/usr/local/",
      "logRoot" => nil,
      "status" => "running"
    })
  end

  def workload_inspect_json do
    Jason.encode!([
      %{
        "configuration" => %{
          "descriptor" => %{
            "digest" => @index_digest,
            "mediaType" => "application/vnd.docker.distribution.manifest.list.v2+json",
            "size" => 772
          },
          "name" => @workload_alias
        },
        "variants" => [
          %{
            "digest" => @manifest_digest,
            "platform" => %{"os" => "linux", "architecture" => "arm64", "variant" => "v8"},
            "config" => %{
              "os" => "linux",
              "architecture" => "arm64",
              "variant" => "v8",
              "config" => %{"Env" => @env, "Labels" => @labels}
            }
          }
        ]
      }
    ])
  end

  def vminit_inspect_json do
    Jason.encode!([
      %{
        "configuration" => %{
          "descriptor" => %{
            "digest" => "sha256:#{@vminit_index_hex}",
            "mediaType" => "application/vnd.oci.image.index.v1+json",
            "size" => 512
          },
          "name" => @vminit_alias
        },
        "variants" => [
          %{
            "digest" => @vminit_manifest_digest,
            "platform" => %{"os" => "linux", "architecture" => "arm64", "variant" => "v8"},
            "config" => %{"os" => "linux", "architecture" => "arm64", "variant" => "v8"}
          }
        ]
      }
    ])
  end

  setup do
    FakeRuntime.reset()
    bindings = valid_bindings()
    policy = valid_policy()
    plan = valid_plan()
    plugin_bytes = @plugin_toml
    config_sha = :crypto.hash(:sha256, plugin_bytes) |> Base.encode16(case: :lower)

    bindings =
      put_in(bindings, [:runtime_plugin_config_identity], %{
        bindings.runtime_plugin_config_identity
        | sha256: config_sha
      })

    FakeRuntime.set_bindings(bindings)
    FakeRuntime.set_policy(policy)
    FakeRuntime.set_plan(plan)
    FakeRuntime.set_plugin_bytes(plugin_bytes)
    FakeRuntime.set_executables(valid_executables(bindings))
    :ok
  end

  describe "positive admission probe" do
    test "admits realistic projection through fake runtime" do
      assert {:ok, receipt} = Prober.probe_for_test(30_000, runtime: FakeRuntime)
      assert receipt["admitted"] == true
      assert receipt["runtime"]["cli_version"] == "1.1.0"
      assert receipt["control_plane"]["admitted"] == true
      assert receipt["image"]["execution_reference"] == @workload_alias
      assert receipt["vminit"]["execution_reference"] == @vminit_alias
      assert Jason.encode!(receipt)
      refute inspect(receipt) =~ "source_root"
      refute inspect(receipt) =~ "materialization_entries"
      refute inspect(receipt) =~ "launchctl"
    end

    test "one event log: five resolves before first run; three codesign before first container" do
      assert {:ok, _} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

      events = FakeRuntime.events()

      resolve_events =
        Enum.filter(events, fn
          {:resolve, _} -> true
          _ -> false
        end)

      assert Enum.map(resolve_events, fn {:resolve, path} -> path end) == [
               "/usr/local/bin/container",
               "/usr/bin/codesign",
               "/bin/launchctl",
               "/usr/bin/id",
               "/usr/bin/sw_vers"
             ]

      first_run_idx =
        Enum.find_index(events, fn
          {:run, _, _} -> true
          _ -> false
        end)

      last_resolve_idx =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {ev, _} -> match?({:resolve, _}, ev) end)
        |> List.last()
        |> elem(1)

      assert last_resolve_idx < first_run_idx

      codesign_idxs =
        events
        |> Enum.with_index()
        |> Enum.filter(fn
          {{:run, "/usr/bin/codesign", _}, _} -> true
          _ -> false
        end)
        |> Enum.map(&elem(&1, 1))

      assert length(codesign_idxs) == 3

      first_container_idx =
        Enum.find_index(events, fn
          {:run, "/usr/local/bin/container", _} -> true
          _ -> false
        end)

      assert first_container_idx
      assert Enum.max(codesign_idxs) < first_container_idx

      runs = FakeRuntime.runs()
      paths_args = Enum.map(runs, fn r -> {r.path, r.args} end)

      assert {"/usr/bin/id", ["-u"]} in paths_args
      assert {"/usr/bin/sw_vers", ["-productVersion"]} in paths_args

      assert {"/bin/launchctl", ["print", "gui/501/com.apple.container.apiserver"]} in paths_args

      assert {"/usr/local/bin/container", ["system", "version", "--format", "json"]} in paths_args
      assert {"/usr/local/bin/container", ["system", "status", "--format", "json"]} in paths_args

      assert {"/usr/local/bin/container", ["image", "inspect", @workload_alias]} in paths_args
      assert {"/usr/local/bin/container", ["image", "inspect", @vminit_alias]} in paths_args

      codesign_runs = Enum.filter(runs, &(&1.path == "/usr/bin/codesign"))
      assert length(codesign_runs) == 3

      for run <- codesign_runs do
        assert Enum.take(run.args, 3) == ["--verify", "--strict", "--all-architectures"]
        assert Enum.any?(run.args, &String.starts_with?(&1, "-R="))
      end

      assert FakeRuntime.verify_order() == [
               "/usr/local/bin/container",
               "/usr/bin/codesign",
               "/bin/launchctl",
               "/usr/bin/id",
               "/usr/bin/sw_vers"
             ]
    end

    test "every run uses cwd root, clear_env, remaining timeout, and bounded output" do
      assert {:ok, _} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

      for run <- FakeRuntime.runs() do
        assert run.opts[:cwd] == "/"
        assert run.opts[:clear_env] == true
        assert is_integer(run.opts[:timeout]) and run.opts[:timeout] > 0
        assert is_integer(run.opts[:max_output_bytes]) and run.opts[:max_output_bytes] > 0
      end
    end

    test "never issues forbidden mutating or network verbs" do
      assert {:ok, _} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

      forbidden = ~w(pull fetch build tag create start run registry push login)
      flat = FakeRuntime.runs() |> Enum.flat_map(& &1.args)

      for verb <- forbidden do
        refute verb in flat
      end
    end
  end

  describe "failure modes" do
    test "CLI executable/binding mismatch fails closed" do
      exes = :persistent_term.get({FakeRuntime, :executables})
      exe = Map.fetch!(exes, "/usr/local/bin/container")
      bad = %{exe | sha256: String.duplicate("00", 32)}
      FakeRuntime.set_executables(Map.put(exes, "/usr/local/bin/container", bad))

      assert {:error, :cli_executable_identity_mismatch} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "role path mismatch against fixed ControlPlane path fails before codesign" do
      bindings = :persistent_term.get({FakeRuntime, :bindings})

      bad =
        put_in(bindings, [:cli_identity], %{
          bindings.cli_identity
          | path: "/tmp/evil-container"
        })

      FakeRuntime.set_bindings(bad)

      # Match CLI uses executable path vs identity path — identity path drift fails match first.
      # Force matching identity path on executable while keeping ControlPlane mismatch via
      # apiserver role instead:
      FakeRuntime.reset()
      setup_defaults_after_reset()
      bindings = :persistent_term.get({FakeRuntime, :bindings})

      bad =
        put_in(bindings, [:apiserver_identity], %{
          bindings.apiserver_identity
          | path: "/tmp/evil-apiserver"
        })

      FakeRuntime.set_bindings(bad)

      assert {:error, {:role_path_mismatch, :apiserver}} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)

      refute Enum.any?(FakeRuntime.runs(), &(&1.path == "/usr/local/bin/container"))
    end

    test "control-plane bindings drift at final revalidation fails closed" do
      FakeRuntime.set_checkout_bindings_mode(:ok_then_drift)

      assert {:error, :control_plane_bindings_drift} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "image policy drift at final revalidation fails closed" do
      FakeRuntime.set_checkout_policy_mode(:ok_then_drift)

      assert {:error, :image_policy_drift} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "compact baseline receipt drift at final revalidation fails closed" do
      FakeRuntime.set_checkout_plan_mode(:ok_then_drift)

      assert {:error, :baseline_receipt_drift} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "codesign failure fails closed" do
      FakeRuntime.set_run_handler(fn exe, args, _opts ->
        if exe.path == "/usr/bin/codesign" do
          {:ok,
           %{
             exit_code: 1,
             stdout: "",
             stderr: "",
             duration_ms: 1,
             timed_out: false,
             killed: false,
             output_truncated: false,
             output_limit_exceeded: false
           }}
        else
          default_run_dispatch(exe.path, args)
        end
      end)

      assert {:error, {:codesign_failed, _role}} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "nonzero exit, timeout, output limit, cancellation, containment fail closed" do
      for result <- [
            %{
              exit_code: 2,
              stdout: "",
              stderr: "",
              duration_ms: 1,
              timed_out: false,
              killed: false,
              output_truncated: false,
              output_limit_exceeded: false
            },
            %{
              exit_code: 137,
              stdout: "",
              stderr: "",
              duration_ms: 1,
              timed_out: true,
              killed: true,
              output_truncated: false,
              output_limit_exceeded: false
            },
            %{
              exit_code: 0,
              stdout: "x",
              stderr: "",
              duration_ms: 1,
              timed_out: false,
              killed: true,
              output_truncated: true,
              output_limit_exceeded: true
            },
            %{
              exit_code: 137,
              stdout: "",
              stderr: "",
              duration_ms: 1,
              timed_out: false,
              killed: true,
              cancelled: true,
              output_truncated: false,
              output_limit_exceeded: false
            },
            %{
              exit_code: 137,
              stdout: "",
              stderr: "",
              duration_ms: 1,
              timed_out: false,
              killed: true,
              containment_failure: true,
              output_truncated: false,
              output_limit_exceeded: false
            }
          ] do
        FakeRuntime.reset()
        setup_defaults_after_reset()

        FakeRuntime.set_run_handler(fn _exe, _args, _opts -> {:ok, result} end)

        assert {:error, reason} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

        assert reason in [
                 :probe_nonzero_exit,
                 :probe_timeout,
                 :probe_output_limit,
                 :probe_cancelled,
                 :probe_containment_failure,
                 {:codesign_failed, :cli},
                 {:codesign_failed, :apiserver},
                 {:codesign_failed, :plugin}
               ]
      end
    end

    test "deadline exhaustion during process run fails closed" do
      FakeRuntime.set_run_handler(fn _exe, _args, _opts ->
        FakeRuntime.advance_mono(60_000)

        {:ok,
         %{
           exit_code: 0,
           stdout: "",
           stderr: "",
           duration_ms: 1,
           timed_out: false,
           killed: false,
           output_truncated: false,
           output_limit_exceeded: false
         }}
      end)

      assert {:error, reason} = Prober.probe_for_test(10, runtime: FakeRuntime)

      assert reason == :deadline_exhausted
    end

    test "deadline exhaustion before plugin config IO fails closed" do
      FakeRuntime.set_run_handler(fn exe, args, _opts ->
        result = default_run_dispatch(exe.path, args)

        if exe.path == "/usr/local/bin/container" and match?(["image", "inspect", _], args) and
             String.contains?(List.last(args), "vminit") do
          FakeRuntime.advance_mono(100_000)
        end

        result
      end)

      assert {:error, :deadline_exhausted} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime)

      refute :read_plugin_config in FakeRuntime.events()
    end

    test "deadline exhaustion after plugin config IO fails closed" do
      FakeRuntime.set_advance_on(:read_plugin_config, 100_000)

      assert {:error, :deadline_exhausted} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime)

      assert :read_plugin_config in FakeRuntime.events()
      refute :prove_user_plugin_root_absent in FakeRuntime.events()
    end

    test "deadline exhaustion after user-plugin absence proof fails closed" do
      FakeRuntime.set_advance_on(:prove_user_plugin_root_absent, 100_000)

      assert {:error, :deadline_exhausted} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime)

      assert :prove_user_plugin_root_absent in FakeRuntime.events()
    end

    test "deadline exhaustion during authority revalidation fails closed" do
      FakeRuntime.set_advance_on_after(:checkout_bindings, 100_000, 1)

      assert {:error, :deadline_exhausted} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime)
    end

    test "deadline exhaustion during executable revalidation fails closed" do
      FakeRuntime.set_advance_on(:verify_executable, 100_000)

      assert {:error, :deadline_exhausted} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime)
    end

    test "total output exhaustion fails closed" do
      huge = String.duplicate("x", 1_048_576 + 64)

      FakeRuntime.set_run_handler(fn exe, args, _opts ->
        if exe.path == "/usr/bin/id" do
          {:ok,
           %{
             exit_code: 0,
             stdout: huge,
             stderr: "",
             duration_ms: 1,
             timed_out: false,
             killed: false,
             output_truncated: false,
             output_limit_exceeded: false
           }}
        else
          default_run_dispatch(exe.path, args)
        end
      end)

      assert {:error, reason} = Prober.probe_for_test(30_000, runtime: FakeRuntime)
      assert reason in [:output_budget_exhausted, :probe_command_failed]
    end

    test "invalid uid output is rejected before launchctl" do
      FakeRuntime.set_run_handler(fn exe, args, _opts ->
        case {exe.path, args} do
          {"/usr/bin/id", ["-u"]} ->
            ok("not-a-uid\n")

          {"/usr/bin/codesign", _} ->
            ok("")

          _ ->
            default_run_dispatch(exe.path, args)
        end
      end)

      assert {:error, :invalid_uid_output} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)

      refute Enum.any?(FakeRuntime.runs(), &(&1.path == "/bin/launchctl"))
    end

    test "oversized plugin config and hash/identity drift fail closed" do
      for mode <- [:too_large, :hash_mismatch, :identity_drift] do
        FakeRuntime.reset()
        setup_defaults_after_reset()
        FakeRuntime.set_plugin_mode(mode)

        assert {:error, reason} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

        assert reason in [
                 :plugin_config_too_large,
                 :plugin_config_hash_mismatch,
                 :identity_mismatch,
                 :plugin_config_read_failed
               ]
      end
    end

    test "user plugin root presence fails closed" do
      FakeRuntime.set_user_plugin_mode(:present)

      assert {:error, :user_plugin_root_present} =
               Prober.probe_for_test(30_000, runtime: FakeRuntime)
    end

    test "callback raise/throw/exit are redacted" do
      for mode <- [:raise, :throw, :exit] do
        FakeRuntime.reset()
        setup_defaults_after_reset()
        FakeRuntime.set_callback_mode(mode)

        assert {:error, :probe_failed} = Prober.probe_for_test(30_000, runtime: FakeRuntime)
      end
    end

    test "malformed options and deadlines fail closed" do
      assert {:error, :invalid_probe_deadline} = Prober.probe(0)
      assert {:error, :invalid_probe_deadline} = Prober.probe(-1)
      assert {:error, :invalid_probe_deadline} = Prober.probe("30")
      assert {:error, :invalid_probe_deadline} = Prober.probe(300_001)

      assert {:error, :invalid_probe_deadline} =
               Prober.probe_for_test(300_001, runtime: FakeRuntime)

      assert {:error, :unknown_probe_test_option} = Prober.probe_for_test(1_000, foo: 1)

      assert {:error, :duplicate_probe_test_option} =
               Prober.probe_for_test(1_000, runtime: FakeRuntime, runtime: FakeRuntime)

      assert {:error, :malformed_probe_test_options} = Prober.probe_for_test(1_000, %{})
    end
  end

  describe "security regression" do
    @tag :security_regression
    test "security regression: codesign completes for all three roles before first container run" do
      assert {:ok, _} = Prober.probe_for_test(30_000, runtime: FakeRuntime)

      events = FakeRuntime.events()

      codesign_paths =
        events
        |> Enum.filter(fn
          {:run, "/usr/bin/codesign", _args} -> true
          _ -> false
        end)
        |> Enum.map(fn {:run, _, args} -> List.last(args) end)

      assert codesign_paths == [
               ControlPlane.cli_path(),
               ControlPlane.apiserver_path(),
               ControlPlane.plugin_path()
             ]

      first_container =
        Enum.find_index(events, fn
          {:run, "/usr/local/bin/container", _} -> true
          _ -> false
        end)

      last_codesign =
        events
        |> Enum.with_index()
        |> Enum.filter(fn
          {{:run, "/usr/bin/codesign", _}, _} -> true
          _ -> false
        end)
        |> List.last()
        |> elem(1)

      assert last_codesign < first_container

      # CLI identity matched before any process run.
      first_run =
        Enum.find_index(events, fn
          {:run, _, _} -> true
          _ -> false
        end)

      assert first_run
      # No container before codesign; first runs are codesign.
      assert match?({:run, "/usr/bin/codesign", _}, Enum.at(events, first_run))
    end

    @tag :security_regression
    test "security regression: caller-nominated policy/path/executable/authority cannot enter production probe API" do
      assert function_exported?(Prober, :probe, 1)
      refute function_exported?(Prober, :probe, 2)

      assert {:error, :invalid_probe_deadline} =
               Prober.probe(%{policy: valid_policy(), path: "/evil"})

      assert {:ok, receipt} = Prober.probe_for_test(30_000, runtime: FakeRuntime)
      assert receipt["image"]["execution_reference"] == @workload_alias
      assert receipt["vminit"]["execution_reference"] == @vminit_alias

      inspect_args =
        FakeRuntime.runs()
        |> Enum.filter(&(&1.path == "/usr/local/bin/container"))
        |> Enum.map(& &1.args)
        |> Enum.filter(&match?(["image", "inspect", _], &1))

      assert ["image", "inspect", @workload_alias] in inspect_args
      assert ["image", "inspect", @vminit_alias] in inspect_args

      refute Enum.any?(inspect_args, fn ["image", "inspect", ref] ->
               String.contains?(ref, "docker.io") or String.contains?(ref, "evil")
             end)
    end
  end

  describe "public spawn facade preflight" do
    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp setup_defaults_after_reset do
    bindings = valid_bindings()
    plugin_bytes = @plugin_toml
    config_sha = :crypto.hash(:sha256, plugin_bytes) |> Base.encode16(case: :lower)

    bindings =
      put_in(bindings, [:runtime_plugin_config_identity], %{
        bindings.runtime_plugin_config_identity
        | sha256: config_sha
      })

    FakeRuntime.set_bindings(bindings)
    FakeRuntime.set_policy(valid_policy())
    FakeRuntime.set_plan(valid_plan())
    FakeRuntime.set_plugin_bytes(plugin_bytes)
    FakeRuntime.set_executables(valid_executables(bindings))
  end

  defp default_run_dispatch(path, args) do
    case {path, args} do
      {"/usr/bin/id", ["-u"]} ->
        ok("501\n")

      {"/usr/bin/sw_vers", ["-productVersion"]} ->
        ok("26.5.2\n")

      {"/bin/launchctl", ["print", "gui/501/com.apple.container.apiserver"]} ->
        ok(@launchctl_clean)

      {"/usr/local/bin/container", ["system", "version", "--format", "json"]} ->
        ok(system_version_json())

      {"/usr/local/bin/container", ["system", "status", "--format", "json"]} ->
        ok(system_status_json())

      {"/usr/local/bin/container", ["image", "inspect", ref]} ->
        cond do
          String.contains?(ref, "workload") ->
            ok(workload_inspect_json())

          String.contains?(ref, "vminit") ->
            ok(vminit_inspect_json())

          true ->
            {:ok,
             %{
               exit_code: 1,
               stdout: "",
               stderr: "",
               duration_ms: 1,
               timed_out: false,
               killed: false,
               output_truncated: false,
               output_limit_exceeded: false
             }}
        end

      {"/usr/bin/codesign", _} ->
        ok("")

      _ ->
        {:ok,
         %{
           exit_code: 1,
           stdout: "",
           stderr: "",
           duration_ms: 1,
           timed_out: false,
           killed: false,
           output_truncated: false,
           output_limit_exceeded: false
         }}
    end
  end

  defp ok(stdout) do
    {:ok,
     %{
       exit_code: 0,
       stdout: stdout,
       stderr: "",
       duration_ms: 1,
       timed_out: false,
       killed: false,
       output_truncated: false,
       output_limit_exceeded: false
     }}
  end

  defp valid_policy do
    %{
      image: @image,
      manifest_digest: @manifest_digest,
      vminit_image: @vminit_image,
      vminit_manifest_digest: @vminit_manifest_digest,
      env: @env,
      labels: @labels,
      mix_lock_digest: @mix_lock_hex,
      baseline_tree_digest: @tree_hex,
      toolchain: %{erlang: @erlang_version, elixir: @elixir_version}
    }
  end

  defp valid_receipt do
    %{
      "schema" => "1",
      "platform" => "linux/arm64",
      "image_index_digest" => @index_digest,
      "image_manifest_digest" => @manifest_digest,
      "mix_lock_digest" => @mix_lock_hex,
      "baseline_tree_digest" => @tree_hex,
      "toolchain" => %{"erlang" => @erlang_version, "elixir" => @elixir_version},
      "entry_count" => 1,
      "total_bytes" => 0
    }
  end

  defp valid_plan do
    %{
      "kind" => "linux_dependency_baseline_source",
      "source_root" => "/var/lib/arbor/linux-deps-source",
      "manifest_path" => "/var/lib/arbor/linux-deps-manifest.json",
      "receipt" => valid_receipt(),
      "materialization_entries" => [
        %{"path" => "hex/x", "sha256" => String.duplicate("1", 64)}
      ],
      "evidence_only" => true
    }
  end

  defp identity(path, sha, executable?, mode) do
    %Identity{
      path: path,
      type: :regular,
      device: 1,
      inode: :erlang.phash2(path),
      size: 4_096,
      mtime: 1_700_000_000,
      ctime: 1_700_000_000,
      mode: mode,
      uid: 0,
      gid: 0,
      sha256: sha,
      executable_required: executable?
    }
  end

  defp executable_from_identity(%Identity{} = id, name) do
    %Executable{
      name: name,
      path: id.path,
      device: id.device,
      inode: id.inode,
      size: id.size,
      mtime: id.mtime,
      ctime: id.ctime,
      mode: id.mode,
      sha256: id.sha256
    }
  end

  defp valid_bindings do
    %{
      cli_identity: identity(ControlPlane.cli_path(), @cli_sha, true, @exec_mode),
      apiserver_identity: identity(ControlPlane.apiserver_path(), @api_sha, true, @exec_mode),
      runtime_plugin_identity:
        identity(ControlPlane.plugin_path(), @plugin_sha, true, @exec_mode),
      runtime_plugin_config_identity:
        identity(ControlPlane.plugin_config_path(), @config_sha, false, @file_mode),
      kernel_identity:
        identity(
          "/usr/local/share/container/kernels/default.kernel",
          @kernel_sha,
          false,
          @file_mode
        ),
      app_root: @app_root
    }
  end

  defp valid_executables(bindings) do
    %{
      "/usr/local/bin/container" => executable_from_identity(bindings.cli_identity, "container"),
      "/usr/bin/codesign" =>
        executable_from_identity(
          identity("/usr/bin/codesign", String.duplicate("11", 32), true, @exec_mode),
          "codesign"
        ),
      "/bin/launchctl" =>
        executable_from_identity(
          identity("/bin/launchctl", String.duplicate("22", 32), true, @exec_mode),
          "launchctl"
        ),
      "/usr/bin/id" =>
        executable_from_identity(
          identity("/usr/bin/id", String.duplicate("33", 32), true, @exec_mode),
          "id"
        ),
      "/usr/bin/sw_vers" =>
        executable_from_identity(
          identity("/usr/bin/sw_vers", String.duplicate("44", 32), true, @exec_mode),
          "sw_vers"
        )
    }
  end
end
