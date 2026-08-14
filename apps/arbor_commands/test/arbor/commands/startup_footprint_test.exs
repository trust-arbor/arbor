defmodule Arbor.Commands.StartupFootprintTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.Core
  alias Arbor.Commands.StartupFootprint.PeerProbe
  alias Arbor.Commands.StartupFootprint.PeerRunner
  alias Arbor.Common.SafePath

  @moduletag :fast

  test "production run refuses synthetic sample and peer injection" do
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             StartupFootprint.run(mode: "report", samples: %{})

    assert {:error, {:production_opts_forbid_synthetic, _}} =
             StartupFootprint.run(mode: "report", run_peer: fn _scenario -> {:ok, %{}} end)
  end

  test "peer start opts are fixed and do not accept caller exec or MFA" do
    assert {Arbor.Commands.StartupFootprint.PeerProbe, :measure, 1} = PeerRunner.probe_mfa()
    assert {:ok, opts} = PeerRunner.start_opts()
    assert opts.connection == :standard_io
    assert opts.peer_down == :crash
    assert match?({:halt, _}, opts.shutdown)
    refute Map.has_key?(opts, :args)
    refute Map.has_key?(opts, :env)
    refute Map.has_key?(opts, :name)

    {:ok, exec} = PeerRunner.pinned_erlang_executable()
    assert opts.exec == String.to_charlist(exec)
    assert File.regular?(exec)
    assert Bitwise.band(File.stat!(exec).mode, 0o111) != 0
    refute function_exported?(PeerRunner, :measure_scenario, 2)
    refute function_exported?(PeerRunner, :measure_all, 1)
    assert function_exported?(PeerRunner, :measure_all, 0)
    refute function_exported?(StartupFootprint, :run, 2)
  end

  test "code-path admission fails closed on control bytes, missing dirs, and ceilings" do
    assert {:error, :peer_code_path_empty} = PeerRunner.admit_paths([])
    assert {:error, :peer_code_path_control_byte} = PeerRunner.admit_paths(["/tmp/\nmissing"])
    assert {:error, :peer_code_path_control_byte} = PeerRunner.admit_paths(["/tmp/" <> <<0>>])

    missing =
      Path.join(
        System.tmp_dir!(),
        "sf-missing-#{System.unique_integer([:positive])}"
      )

    assert {:error, {:peer_code_path_unresolved, ^missing, _}} =
             PeerRunner.admit_paths([missing])

    file =
      Path.join(
        System.tmp_dir!(),
        "sf-file-#{System.unique_integer([:positive])}"
      )

    File.write!(file, "not-a-dir")
    on_exit(fn -> File.rm(file) end)

    assert {:error, {:peer_code_path_not_directory, ^file}} = PeerRunner.admit_paths([file])

    too_long = "/" <> String.duplicate("a", 4_097)
    assert {:error, {:peer_code_path_entry_bytes, 4_098}} = PeerRunner.admit_paths([too_long])

    overflow = Enum.map(1..513, fn i -> "/tmp/sf-#{i}" end)
    assert {:error, {:peer_code_path_count, 513}} = PeerRunner.admit_paths(overflow)
  end

  test "malformed list paths fail closed and canonical paths are the byte-ceiling values" do
    assert {:error, :peer_code_path_invalid} = PeerRunner.admit_paths([:not_a_path])
    assert {:error, :peer_code_path_invalid} = PeerRunner.admit_paths([[:not_a_char]])
    assert {:error, :peer_code_path_invalid} = PeerRunner.admit_paths([["not", "codepoints"]])
    assert {:error, :peer_code_path_invalid} = PeerRunner.admit_paths([~c"/tmp" | :tail])

    parent =
      Path.join(
        System.tmp_dir!(),
        "sf-canon-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(parent)
    on_exit(fn -> File.rm_rf(parent) end)

    {:ok, canonical_parent} = SafePath.resolve_real(parent)

    assert {:ok, [admitted_charlist]} =
             PeerRunner.admit_paths([String.to_charlist(canonical_parent)])

    assert admitted_charlist == canonical_parent

    long =
      Enum.reduce(1..3, parent, fn _, acc ->
        next = Path.join(acc, String.duplicate("p", 255))
        File.mkdir_p!(next)
        next
      end)

    link_root = Path.join(parent, "l")
    File.mkdir_p!(link_root)

    {inputs, canonical_total, input_total} =
      Enum.reduce(1..400, {[], 0, 0}, fn i, {acc, canon_bytes, in_bytes} ->
        real = Path.join(long, "d#{i}")
        File.mkdir_p!(real)
        {:ok, canonical} = SafePath.resolve_real(real)
        link = Path.join(link_root, "s#{i}")
        File.ln_s!(canonical, link)
        {[link | acc], canon_bytes + byte_size(canonical), in_bytes + byte_size(link)}
      end)

    assert canonical_total > 256_000
    assert input_total < 256_000
    assert length(inputs) <= 512

    assert {:error, :peer_code_path_total_bytes} =
             PeerRunner.admit_paths(Enum.reverse(inputs))
  end

  test "production PeerRunner and PeerProbe do not export filesystem test operations" do
    root = find_umbrella(__DIR__)

    runner_path =
      Path.join(root, "apps/arbor_commands/lib/arbor/commands/startup_footprint/peer_runner.ex")

    probe_path =
      Path.join(root, "apps/arbor_commands/lib/arbor/commands/startup_footprint/peer_probe.ex")

    shell_path = Path.join(root, "apps/arbor_commands/lib/arbor/commands/startup_footprint.ex")

    support_path =
      Path.join(root, "apps/arbor_commands/test/support/startup_footprint_peer_test_ops.ex")

    runner_src = File.read!(runner_path)
    probe_src = File.read!(probe_path)
    shell_src = File.read!(shell_path)
    support_src = File.read!(support_path)

    refute String.contains?(runner_src, "__test_sleep_touch__")
    refute String.contains?(probe_src, "__test_sleep_touch__")
    refute String.contains?(runner_src, "write_file")
    refute String.contains?(probe_src, "write_file")
    assert String.contains?(support_src, "write_file")
    assert String.contains?(support_src, "defmodule Arbor.Commands.StartupFootprint.PeerTestOps")
    assert String.contains?(shell_src, "PeerRunner.measure_all()")
    refute String.contains?(shell_src, "measure_scenario")

    refute function_exported?(PeerRunner, :__test_sleep_touch__, 2)
    refute function_exported?(PeerRunner, :__test_sleep_touch__, 3)
    refute function_exported?(PeerProbe, :__test_sleep_touch__, 2)
    assert function_exported?(PeerRunner, :__test_run_owned__, 3)
    assert function_exported?(Arbor.Commands.StartupFootprint.PeerTestOps, :sleep_touch, 3)

    runner_defs = classified_public_defs(runner_src)
    probe_defs = classified_public_defs(probe_src)

    assert MapSet.equal?(
             runner_defs.test,
             MapSet.new([
               :__test_run_owned__,
               :__test_peer_call__,
               :__test_consult_app_file__
             ])
           )

    refute Enum.any?(runner_defs.prod, &test_export?/1)
    assert probe_defs.test == MapSet.new([:__test_app_applications__])
    refute Enum.any?(probe_defs.prod, &test_export?/1)
  end

  test "current code path admits existing canonical directories" do
    assert {:ok, paths} = PeerRunner.admit_current_code_path()
    assert paths != []
    assert Enum.all?(paths, &is_binary/1)
    assert Enum.all?(paths, &File.dir?/1)
    assert Enum.all?(paths, &(not String.contains?(&1, <<0>>)))
  end

  test "check mode compares injected samples against policy and does not write" do
    root = tmp_root()
    policy_path =
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json")
    before = File.read!(policy_path)

    samples = %{
      "baseline" => sample("baseline", 101, 0, 0),
      "proposed_gated" => sample("proposed_gated", 102, 0, 0),
      "proposed_eager" => sample("proposed_eager", 103, 5, 1)
    }

    assert {:ok, report} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               json: true,
               samples: samples
             )

    assert report["status"] == "ok"
    assert report["mode"] == "check"
    assert File.read!(policy_path) == before

    over = put_in(samples, ["baseline", "process_count_delta"], 9_999)

    assert {:ok, failed} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               samples: over
             )

    assert failed["status"] == "failed"
    assert File.read!(policy_path) == before

    File.rm_rf(root)
  end

  defp sample(scenario, pid, children, side_effects) do
    %{
      "scenario" => scenario,
      "os_pid" => pid,
      "process_count_delta" => 8,
      "supervisor_children" => children,
      "ets_table_count_delta" => 2,
      "ets_memory_words_delta" => 100,
      "beam_memory_bytes_delta" => 1_000,
      "boot_time_us" => 50,
      "logger_filter_count" => side_effects,
      "telemetry_handler_count" => side_effects,
      "started_owner_apps" => [],
      "started_runtime_apps" =>
        if(scenario in ["proposed_gated", "proposed_eager"], do: ["os_mon"], else: []),
      "raw_errors" => []
    }
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "sf-cli-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "apps/arbor_kernel"))
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))
    File.write!(Path.join(root, "apps/arbor_kernel/mix.exs"), "defmodule K do\nend\n")

    policy = %{
      "schema" => Core.policy_schema(),
      "version" => 1,
      "policy_version" => Core.policy_version(),
      "decision" => %{
        "status" => "candidate",
        "choice" => "measure_only",
        "rationale" => "CLI closure test policy.",
        "reversible" => true
      },
      "scenarios" => Core.scenarios(),
      "budgets" => %{
        "baseline" => bounds(0, 16, 0, 0),
        "proposed_gated" => bounds(0, 16, 0, 0),
        "proposed_eager" => bounds(1, 100, 1, 8)
      }
    }

    File.write!(
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json"),
      Jason.encode!(policy)
    )

    root
  end

  defp bounds(min_children, max_process, min_side, max_side) do
    %{
      "process_count_delta" => %{"min" => 0, "max" => max_process},
      "supervisor_children" => %{"min" => min_children, "max" => 100},
      "ets_table_count_delta" => %{"min" => 0, "max" => 50},
      "ets_memory_words_delta" => %{"min" => 0, "max" => 10_000},
      "beam_memory_bytes_delta" => %{"min" => 0, "max" => 1_000_000},
      "boot_time_us" => %{"min" => 0, "max" => 1_000_000},
      "logger_filter_count" => %{"min" => min_side, "max" => max_side},
      "telemetry_handler_count" => %{"min" => min_side, "max" => max_side}
    }
  end

  defp find_umbrella(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_umbrella(Path.dirname(dir))
    end
  end

  defp test_export?(name) when is_atom(name) do
    String.starts_with?(Atom.to_string(name), "__test_")
  end

  defp classified_public_defs(src) do
    {:ok, ast} = Code.string_to_quoted(src)

    ast
    |> module_body()
    |> List.wrap()
    |> Enum.reduce(%{prod: MapSet.new(), test: MapSet.new()}, fn node, acc ->
      classify_node(node, acc)
    end)
  end

  defp classify_node({:if, _, [condition, [do: block]]}, acc) do
    if test_env_guard?(condition) do
      %{acc | test: MapSet.union(acc.test, defs_in(block))}
    else
      %{acc | prod: MapSet.union(acc.prod, defs_in(block))}
    end
  end

  defp classify_node(other, acc) do
    %{acc | prod: MapSet.union(acc.prod, defs_in(other))}
  end

  defp test_env_guard?({:==, _, [{{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []}, :test]}),
    do: true

  defp test_env_guard?(_), do: false

  defp module_body({:defmodule, _, [_, [do: {:__block__, _, body}]]}), do: body
  defp module_body({:defmodule, _, [_, [do: body]]}), do: [body]

  defp defs_in(ast) do
    ast
    |> Macro.prewalk(MapSet.new(), fn
      {:def, _, [{name, _, _args} | _]} = node, acc when is_atom(name) ->
        {node, MapSet.put(acc, name)}

      other, acc ->
        {other, acc}
    end)
    |> elem(1)
  end
end
