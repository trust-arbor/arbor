defmodule Arbor.Scheduler.Workers.PipelineRunnerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, PipelinePaths}
  alias Arbor.Scheduler.Test.WorkdirReplacingOrchestrator
  alias Arbor.Scheduler.Workers.PipelineRunner
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  defmodule OrchestratorStub do
    def run_file_as(path, agent_id, signer, opts) do
      test_pid = Application.fetch_env!(:arbor_scheduler, :pipeline_runner_test_pid)
      identity_registered? = match?({:ok, _}, Arbor.Security.Identity.Registry.lookup(agent_id))
      send(test_pid, {:run_file_as, path, agent_id, signer, opts, identity_registered?})
      {:ok, %{status: :completed}}
    end
  end

  defmodule LegacyFacadeStub do
    def run_file_as(_agent_id, _path, _opts), do: {:ok, %{status: :completed}}
  end

  setup do
    base =
      System.tmp_dir!()
      |> Path.join("pipeline_runner_test_#{System.unique_integer([:positive])}")

    root = Path.join(base, "allowed")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    {:ok, issuer} = Identity.generate()
    :ok = IdentityRegistry.register(issuer)

    {:ok, envelope} =
      Capability.new(
        resource_uri: "arbor://fs/write/reports/**",
        principal_id: issuer.agent_id
      )

    :ok = IssuerRegistry.register(issuer.agent_id, envelope, reason: "pipeline_runner_test")

    restore_env(:pipeline_roots)
    restore_env(:orchestrator_module)
    restore_env(:pipeline_runner_test_pid)
    restore_env(:pipeline_runner_workdir_replacement)

    Application.put_env(:arbor_scheduler, :pipeline_roots, %{"test" => root})
    Application.put_env(:arbor_scheduler, :orchestrator_module, OrchestratorStub)
    Application.put_env(:arbor_scheduler, :pipeline_runner_test_pid, self())

    on_exit(fn ->
      IssuerRegistry.revoke(issuer.agent_id, "test cleanup")
      File.rm_rf!(base)
    end)

    {:ok, issuer: issuer, root: root, outside: outside}
  end

  describe "exact attestation execution" do
    test "security regression: exact graph, path, workdir, and args call run_file_as/4", %{
      issuer: issuer,
      root: root
    } do
      initial_args = %{"mode" => "review", "items" => ["a", "b"]}

      %{dot: dot, hash: hash, workdir: workdir} =
        write_attested_pipeline(root, "exact", issuer, initial_args: initial_args)

      assert :ok = PipelineRunner.perform(job(dot, initial_args))

      assert_receive {:run_file_as, canonical_dot, agent_id, signer, opts, true}
      assert {:ok, expected_dot} = Arbor.Common.SafePath.resolve_real(dot)
      assert canonical_dot == expected_dot
      assert is_function(signer, 1)
      assert opts[:graph_hash] == hash
      assert opts[:workdir] == workdir
      assert opts[:initial_values] == initial_args
      assert opts[:author_id] == issuer.agent_id
      refute Keyword.has_key?(opts, :signer)
      refute Map.has_key?(opts[:initial_values], "session.agent_id")

      assert {:error, :not_found} = IdentityRegistry.lookup(agent_id)
    end

    test "the real facade exposes path, principal, signer, opts in that order", %{root: root} do
      path = Path.join(root, "facade_contract.dot")
      File.write!(path, dot_source("facade_contract"))
      facade = Arbor.Orchestrator

      assert Code.ensure_loaded?(facade)
      assert function_exported?(facade, :run_file_as, 4)

      assert {:error, :invalid_execution_principal} =
               apply(facade, :run_file_as, [path, "", fn _ -> {:error, :unused} end, []])

      assert {:error, :signer_required} =
               apply(facade, :run_file_as, [path, "agent_contract_probe", :not_a_signer, []])
    end

    test "clean fallback when only legacy run_file_as/3 is available", %{
      issuer: issuer,
      root: root
    } do
      %{dot: dot} = write_attested_pipeline(root, "missing_facade", issuer)
      Application.put_env(:arbor_scheduler, :orchestrator_module, LegacyFacadeStub)

      assert {:error, :orchestrator_run_file_as_unavailable} =
               PipelineRunner.perform(job(dot, %{}))

      refute_received {:run_file_as, _, _, _, _, _}
    end
  end

  describe "authorship and input security regressions" do
    test "security regression: copied caps beside another DOT are rejected", %{
      issuer: issuer,
      root: root
    } do
      %{caps: source_caps} = write_attested_pipeline(root, "original", issuer)
      copied_dot = Path.join(root, "copied.dot")
      copied_caps = Path.join(root, "copied.caps.json")
      File.write!(copied_dot, File.read!(Path.join(root, "original.dot")))
      File.cp!(source_caps, copied_caps)

      assert {:discard, reason} = PipelineRunner.perform(job(copied_dot, %{}))
      assert reason =~ "pipeline_identity_mismatch"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "security regression: editing DOT after signing is rejected before Engine", %{
      issuer: issuer,
      root: root
    } do
      %{dot: dot} = write_attested_pipeline(root, "modified", issuer)
      File.write!(dot, "\n// modified after review\n", [:append])

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "graph_hash_mismatch"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "security regression: changed job args are rejected before identity mint", %{
      issuer: issuer,
      root: root
    } do
      %{dot: dot} =
        write_attested_pipeline(root, "args", issuer, initial_args: %{"operation" => "review"})

      assert {:discard, reason} =
               PipelineRunner.perform(job(dot, %{"operation" => "publish"}))

      assert reason =~ "initial_args_mismatch"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "security regression: changed workdir is rejected", %{
      issuer: issuer,
      root: root,
      outside: outside
    } do
      %{dot: dot} = write_attested_pipeline(root, "workdir", issuer)
      {:ok, other_workdir} = PipelinePaths.resolve_workdir(outside)

      assert {:discard, reason} =
               PipelineRunner.perform(job(dot, %{}, %{"workdir" => other_workdir}))

      assert reason =~ "workdir_mismatch"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "security regression: workdir replaced by a symlink before dispatch is rejected", %{
      issuer: issuer,
      root: root,
      outside: outside
    } do
      workdir = Path.join(outside, "attested_workdir")
      replacement = Path.join(outside, "replacement_workdir")
      File.mkdir_p!(workdir)
      File.mkdir_p!(replacement)

      %{dot: dot, workdir: canonical_workdir} =
        write_attested_pipeline(root, "workdir_race", issuer, workdir: workdir)

      {:ok, canonical_replacement} = PipelinePaths.resolve_workdir(replacement)

      Application.put_env(
        :arbor_scheduler,
        :pipeline_runner_workdir_replacement,
        {canonical_workdir, canonical_replacement, self()}
      )

      Application.put_env(
        :arbor_scheduler,
        :orchestrator_module,
        WorkdirReplacingOrchestrator
      )

      beam_path = :code.which(WorkdirReplacingOrchestrator)
      assert is_list(beam_path)
      :code.purge(WorkdirReplacingOrchestrator)
      :code.delete(WorkdirReplacingOrchestrator)

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert_receive {:workdir_replaced, :ok, ^canonical_workdir, ^canonical_replacement}
      assert reason =~ "attested_workdir_changed"
      refute_received {:replacement_stub_dispatched, _, _, _, _}
    end

    test "security regression: invalid manifest signature is rejected", %{
      issuer: issuer,
      root: root
    } do
      %{dot: dot, caps: caps} = write_attested_pipeline(root, "signature", issuer)

      raw = Jason.decode!(File.read!(caps))
      tampered = Map.put(raw, "signature", Base.encode64(:crypto.strong_rand_bytes(64)))
      File.write!(caps, Jason.encode!(tampered))

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "invalid_signature"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "security regression: legacy version 1 manifest is rejected", %{
      issuer: issuer,
      root: root
    } do
      dot = Path.join(root, "legacy.dot")
      caps = Path.join(root, "legacy.caps.json")
      File.write!(dot, dot_source("legacy"))

      File.write!(
        caps,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => issuer.agent_id,
          "capabilities" => [],
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
        })
      )

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "legacy_version"
      refute_received {:run_file_as, _, _, _, _, _}
    end
  end

  describe "canonical path security regressions" do
    test "absolute pipeline path outside configured roots is rejected", %{
      outside: outside
    } do
      dot = Path.join(outside, "absolute.dot")
      File.write!(dot, dot_source("absolute"))

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "outside_allowed_roots"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "pipeline symlink escape is rejected", %{root: root, outside: outside} do
      target = Path.join(outside, "target.dot")
      link = Path.join(root, "pipeline_link.dot")
      File.write!(target, dot_source("target"))
      File.ln_s!(target, link)

      assert {:discard, reason} = PipelineRunner.perform(job(link, %{}))
      assert reason =~ "symlink_or_non_regular_file"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "caps-file symlink escape is rejected", %{
      issuer: issuer,
      root: root,
      outside: outside
    } do
      dot = Path.join(root, "caps_link.dot")
      caps_link = Path.join(root, "caps_link.caps.json")
      outside_caps = Path.join(outside, "attestation.caps.json")
      File.write!(dot, dot_source("caps_link"))
      write_manifest(outside_caps, dot, root, issuer, initial_args: %{})
      File.ln_s!(outside_caps, caps_link)

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "caps_path_rejected"
      refute_received {:run_file_as, _, _, _, _, _}
    end

    test "pipeline without a sibling manifest is rejected", %{root: root} do
      dot = Path.join(root, "missing_caps.dot")
      File.write!(dot, dot_source("missing_caps"))

      assert {:discard, reason} = PipelineRunner.perform(job(dot, %{}))
      assert reason =~ "missing caps file"
      refute_received {:run_file_as, _, _, _, _, _}
    end
  end

  describe "worker options" do
    test "keeps bounded retry defaults" do
      assert PipelineRunner.__opts__()[:max_attempts] == 3
      assert PipelineRunner.__opts__()[:queue] == :default
    end

    test "missing pipeline path is discarded" do
      assert {:discard, "missing or invalid pipeline_path"} =
               PipelineRunner.perform(%Oban.Job{args: %{"args" => %{}}})
    end
  end

  defp write_attested_pipeline(root, name, issuer, opts \\ []) do
    dot = Path.join(root, "#{name}.dot")
    caps = Path.join(root, "#{name}.caps.json")
    File.write!(dot, dot_source(name))
    write_manifest(caps, dot, root, issuer, opts)

    {:ok, workdir} = PipelinePaths.resolve_workdir(Keyword.get(opts, :workdir, root))

    %{
      dot: dot,
      caps: caps,
      hash: sha256(File.read!(dot)),
      workdir: workdir
    }
  end

  defp write_manifest(caps_path, dot, root, issuer, opts) do
    {:ok, workdir} = PipelinePaths.resolve_workdir(Keyword.get(opts, :workdir, root))

    {:ok, payload} =
      CapsFile.build(issuer.agent_id, Keyword.get(opts, :capabilities, []),
        pipeline_root: "test",
        pipeline_path: Path.relative_to(dot, root),
        graph_hash: sha256(File.read!(dot)),
        workdir: workdir,
        initial_args: Keyword.get(opts, :initial_args, %{})
      )

    signature = Crypto.sign(CapsFile.signing_payload(payload), issuer.private_key)
    File.write!(caps_path, payload |> CapsFile.manifest_map(signature) |> Jason.encode!())
  end

  defp job(path, initial_args, extra \\ []) do
    args =
      %{"pipeline_path" => path, "args" => initial_args}
      |> Map.merge(Map.new(extra))

    %Oban.Job{args: args}
  end

  defp dot_source(name), do: "digraph #{name} { start [shape=Mdiamond] }"

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_env(key) do
    previous = Application.get_env(:arbor_scheduler, key, :__missing__)

    on_exit(fn ->
      case previous do
        :__missing__ -> Application.delete_env(:arbor_scheduler, key)
        value -> Application.put_env(:arbor_scheduler, key, value)
      end
    end)
  end
end
