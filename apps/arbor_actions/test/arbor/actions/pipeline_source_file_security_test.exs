defmodule Arbor.Actions.Pipeline.SourceFileSecurityTest do
  @moduledoc """
  Security regression: pipeline_run / pipeline_validate must not read source_file
  via SafePath + File.read alone. A principal with pipeline run/validate authority
  but no fs/read must not inspect or execute a repository DOT file.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Actions.Pipeline
  alias Arbor.Actions.Pipeline.{Run, Validate}
  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Security

  @simple_dot """
  digraph SourceFileAuth {
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    start_trust_infrastructure()

    workdir =
      Path.join(
        System.tmp_dir!(),
        "pipeline_source_file_auth_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workdir)
    dot_path = Path.join(workdir, "child.dot")
    File.write!(dot_path, @simple_dot)

    principal = "agent_pipeline_sf_#{System.unique_integer([:positive])}"
    caller = "agent_pipeline_caller_#{System.unique_integer([:positive])}"
    signer = fn _resource -> {:ok, %{signature: "test-fresh-fs-read"}} end

    {:ok, _profile} = Arbor.Trust.create_trust_profile(principal)
    {:ok, _profile} = Arbor.Trust.accept_graduation(principal, "arbor://fs/read")

    granted = []

    on_exit(fn ->
      File.rm_rf(workdir)

      for agent <- [principal, caller] do
        case Security.list_capabilities(agent) do
          {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
          _ -> :ok
        end
      end
    end)

    {:ok,
     workdir: workdir,
     dot_path: dot_path,
     relative_dot: "child.dot",
     principal: principal,
     caller: caller,
     signer: signer,
     granted: granted}
  end

  defp start_trust_infrastructure do
    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp grant!(agent, resource) do
    {:ok, cap} = Security.grant(principal: agent, resource: resource)
    cap
  end

  defp verified_auth(principal, signer) do
    principal
    |> AuthContext.new(signer: signer)
    |> AuthContext.mark_verified()
  end

  defp run_context(principal, signer, workdir, opts \\ []) do
    %{
      auth_context: verified_auth(principal, signer),
      caller_id: Keyword.get(opts, :caller_id, principal),
      workdir: workdir,
      task_id: Keyword.get(opts, :task_id),
      session_id: Keyword.get(opts, :session_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp source_authority!(principal, signer, workdir, relative_dot) do
    {:ok, authority} =
      Pipeline.verified_source_authority(
        %{source_file: relative_dot},
        run_context(principal, signer, workdir)
      )

    authority
  end

  defp with_source_file_read_hook(hook, fun) do
    key = {Pipeline, :source_file_post_read_hook}
    previous = Process.put(key, hook)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  defp deny_source_file_read?(result) do
    match?(
      {:error, :source_file_read_denied},
      result
    ) or
      match?({:error, {:source_file_read_denied, _}}, result) or
      match?({:error, :caller_source_file_authority_missing}, result) or
      match?({:error, {:caller_source_file_authority_missing, _}}, result) or
      match?({:error, :verified_source_file_authority_required}, result) or
      match?({:error, {:invalid_path, _, _}}, result)
  end

  defp auth_passed_or_orchestrator?(result) do
    case result do
      {:ok, _} -> true
      {:error, :orchestrator_not_available} -> true
      {:error, {:orchestrator_unavailable, _}} -> true
      {:error, :unauthorized} -> true
      _ -> false
    end
  end

  describe "security regression — source_file secondary-resource authorization" do
    test "Pipeline.Run denies source_file without execution principal fs/read", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://action/pipeline/run")
      # deliberately no arbor://fs/read*

      result =
        Run.run(
          %{source_file: relative_dot, initial_context: %{}},
          run_context(principal, signer, workdir)
        )

      assert match?({:error, {:source_file_read_denied, _}}, result),
             "expected fs/read denial, got: #{inspect(result)}"
    end

    test "Pipeline.Validate denies source_file without fs/read", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      # Validate must not require pipeline/run; still needs fs/read for source_file.
      result =
        Validate.run(
          %{source_file: relative_dot},
          run_context(principal, signer, workdir)
        )

      assert match?({:error, {:source_file_read_denied, _}}, result),
             "expected fs/read denial, got: #{inspect(result)}"
    end

    test "caller != executor is denied without caller exact read capability", %{
      principal: principal,
      caller: caller,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://action/pipeline/run")
      grant!(principal, "arbor://fs/read#{workdir}/**")
      grant!(caller, "arbor://action/pipeline/run")
      # caller has no fs/read for this path

      result =
        Run.run(
          %{source_file: relative_dot, initial_context: %{}},
          run_context(principal, signer, workdir, caller_id: caller)
        )

      assert result == {:error, :caller_source_file_authority_missing} or
               match?({:error, {:caller_source_file_authority_missing, _}}, result),
             "expected caller read-cap denial, got: #{inspect(result)}"
    end

    test "traversal / outside-workdir path is denied", %{
      principal: principal,
      signer: signer,
      workdir: workdir
    } do
      grant!(principal, "arbor://action/pipeline/run")
      grant!(principal, "arbor://fs/read#{workdir}/**")

      outside =
        Path.join(System.tmp_dir!(), "outside_pipeline_#{System.unique_integer([:positive])}.dot")

      File.write!(outside, @simple_dot)
      on_exit(fn -> File.rm(outside) end)

      # Absolute path outside workdir
      abs_result =
        Run.run(
          %{source_file: outside, initial_context: %{}},
          run_context(principal, signer, workdir)
        )

      assert deny_source_file_read?(abs_result),
             "absolute outside path must be denied, got: #{inspect(abs_result)}"

      # Relative traversal
      trav_result =
        Run.run(
          %{source_file: "../outside_should_not_read.dot", initial_context: %{}},
          run_context(principal, signer, workdir)
        )

      assert deny_source_file_read?(trav_result),
             "traversal path must be denied, got: #{inspect(trav_result)}"
    end

    test "security regression: an in-workdir symlink cannot redirect source_file outside", %{
      principal: principal,
      signer: signer,
      workdir: workdir
    } do
      grant!(principal, "arbor://action/pipeline/run")
      grant!(principal, "arbor://fs/**")

      outside =
        Path.join(
          System.tmp_dir!(),
          "outside_pipeline_link_#{System.unique_integer([:positive])}.dot"
        )

      File.write!(outside, @simple_dot)
      File.ln_s!(outside, Path.join(workdir, "outside-link.dot"))
      on_exit(fn -> File.rm(outside) end)

      assert {:error, {:invalid_path, "outside-link.dot", :path_traversal}} =
               Run.run(
                 %{source_file: "outside-link.dot", initial_context: %{}},
                 run_context(principal, signer, workdir)
               )
    end

    test "security regression: a symlink replacement race discards source_file bytes", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      dot_path: dot_path,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://fs/read#{workdir}/**")
      authority = source_authority!(principal, signer, workdir, relative_dot)
      original_path = Path.join(workdir, "child-original.dot")
      outside_path = workdir <> "_symlink_race_outside.dot"
      File.write!(outside_path, "sensitive replacement bytes")
      on_exit(fn -> File.rm(outside_path) end)

      replace_with_symlink = fn real_path ->
        File.rename!(real_path, original_path)
        File.ln_s!(outside_path, real_path)
      end

      result =
        with_source_file_read_hook(replace_with_symlink, fn ->
          Pipeline.resolve_source(%{source_file: relative_dot}, authority)
        end)

      assert {:error, :source_file_changed_during_read} = result
      refute match?({:ok, _bytes}, result)
      assert {:ok, ^outside_path} = File.read_link(dot_path)
    end

    test "security regression: a regular-file replacement race discards source_file bytes", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://fs/read#{workdir}/**")
      authority = source_authority!(principal, signer, workdir, relative_dot)
      original_path = Path.join(workdir, "child-original.dot")
      replacement = "sensitive replacement bytes"

      replace_with_regular_file = fn real_path ->
        File.rename!(real_path, original_path)
        File.write!(real_path, replacement)
      end

      result =
        with_source_file_read_hook(replace_with_regular_file, fn ->
          Pipeline.resolve_source(%{source_file: relative_dot}, authority)
        end)

      assert {:error, :source_file_changed_during_read} = result
      refute match?({:ok, _bytes}, result)
    end

    test "security regression: workdir replacement during read discards source_file bytes", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://fs/read#{workdir}/**")
      authority = source_authority!(principal, signer, workdir, relative_dot)
      original_workdir = workdir <> "_original"

      on_exit(fn ->
        File.rm_rf(workdir)
        File.rm_rf(original_workdir)
      end)

      replace_workdir = fn _real_path ->
        File.rename!(workdir, original_workdir)
        File.ln_s!(original_workdir, workdir)
      end

      result =
        with_source_file_read_hook(replace_workdir, fn ->
          Pipeline.resolve_source(%{source_file: relative_dot}, authority)
        end)

      assert {:error, :source_file_changed_during_read} = result
      refute match?({:ok, _bytes}, result)
    end

    test "security regression: descriptor-bound source_file double-swap reads opened inode", %{
      principal: principal,
      signer: signer,
      workdir: workdir
    } do
      grant!(principal, "arbor://fs/read#{workdir}/**")

      source_dir = Path.join(workdir, "double-swap")
      original_dir = Path.join(workdir, "double-swap-original")
      source_path = Path.join(source_dir, "child.dot")
      relative_source = "double-swap/child.dot"
      alternate = String.replace(@simple_dot, "SourceFileAuth", "DoubleSwapRace")

      File.mkdir_p!(source_dir)
      File.write!(source_path, @simple_dot)
      refute alternate == @simple_dot
      assert byte_size(alternate) == byte_size(@simple_dot)

      authority = source_authority!(principal, signer, workdir, relative_source)

      double_swap = fn
        :after_open, _real_path ->
          File.rename!(source_dir, original_dir)
          File.mkdir_p!(source_dir)
          File.write!(source_path, alternate)

        :after_read, _real_path ->
          File.rm_rf!(source_dir)
          File.rename!(original_dir, source_dir)
      end

      result =
        with_source_file_read_hook(double_swap, fn ->
          Pipeline.resolve_source(%{source_file: relative_source}, authority)
        end)

      assert {:ok, @simple_dot} = result
      refute result == {:ok, alternate}
      assert File.read!(source_path) == @simple_dot
    end

    test "unchanged authorized source_file returns its bytes", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://fs/read#{workdir}/**")
      authority = source_authority!(principal, signer, workdir, relative_dot)

      assert {:ok, @simple_dot} =
               Pipeline.resolve_source(%{source_file: relative_dot}, authority)
    end

    test "security regression: caller run authority cannot substitute for executor authority", %{
      principal: principal,
      caller: caller,
      signer: signer,
      workdir: workdir
    } do
      grant!(caller, "arbor://action/pipeline/run")

      assert {:error, :execution_principal_pipeline_run_authority_missing} =
               Run.run(
                 %{source: @simple_dot, initial_context: %{}},
                 run_context(principal, signer, workdir, caller_id: caller)
               )
    end

    test "authorized exact path succeeds past the source_file gate", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      grant!(principal, "arbor://action/pipeline/run")
      grant!(principal, "arbor://fs/read#{workdir}/**")

      run_result =
        Run.run(
          %{source_file: relative_dot, initial_context: %{}},
          run_context(principal, signer, workdir)
        )

      assert auth_passed_or_orchestrator?(run_result),
             "authorized run source_file should pass fs gate, got: #{inspect(run_result)}"

      validate_result =
        Validate.run(
          %{source_file: relative_dot},
          run_context(principal, signer, workdir)
        )

      assert auth_passed_or_orchestrator?(validate_result),
             "authorized validate source_file should pass fs gate, got: #{inspect(validate_result)}"
    end

    test "caller != executor succeeds when caller holds exact normalized read cap", %{
      principal: principal,
      caller: caller,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot,
      dot_path: dot_path
    } do
      grant!(principal, "arbor://action/pipeline/run")
      grant!(principal, "arbor://fs/read#{workdir}/**")
      grant!(caller, "arbor://action/pipeline/run")

      # Exact normalized resource (path-embedded, no leading slash on absolute form)
      {:ok, exact_uri} =
        Security.normalize_authorization_resource_uri("arbor://fs/read", file_path: dot_path)

      grant!(caller, exact_uri)

      result =
        Run.run(
          %{source_file: relative_dot, initial_context: %{}},
          run_context(principal, signer, workdir, caller_id: caller)
        )

      assert auth_passed_or_orchestrator?(result),
             "caller with exact read cap should pass, got: #{inspect(result)}"
    end

    test "inline source is unaffected by source_file fs/read gate", %{
      principal: principal,
      signer: signer,
      workdir: workdir
    } do
      grant!(principal, "arbor://action/pipeline/run")
      # no fs/read

      run_result =
        Run.run(
          %{source: @simple_dot, initial_context: %{}},
          run_context(principal, signer, workdir)
        )

      assert auth_passed_or_orchestrator?(run_result),
             "inline Run must not require fs/read, got: #{inspect(run_result)}"

      # Validate inline needs no AuthContext / workdir / fs/read
      validate_result = Validate.run(%{source: @simple_dot}, %{})

      assert auth_passed_or_orchestrator?(validate_result),
             "inline Validate must not require fs/read, got: #{inspect(validate_result)}"
    end

    test "public resolve_source helper fails closed for unauthenticated source_file", %{
      relative_dot: relative_dot
    } do
      assert {:error, :verified_source_file_authority_required} =
               Pipeline.resolve_source(%{source_file: relative_dot})

      assert {:error, :verified_source_file_authority_required} =
               Pipeline.resolve_source(%{source_file: relative_dot}, nil)

      assert {:ok, @simple_dot} = Pipeline.resolve_source(%{source: @simple_dot})
    end

    test "Validate source_file ignores caller-supplied authority params", %{
      principal: principal,
      signer: signer,
      workdir: workdir,
      relative_dot: relative_dot
    } do
      # No AuthContext — only untrusted params claiming agent_id / workdir.
      result =
        Validate.run(
          %{
            source_file: relative_dot,
            agent_id: principal,
            workdir: workdir,
            caller_id: principal
          },
          %{
            agent_id: principal,
            workdir: workdir
          }
        )

      assert result == {:error, :verified_source_file_authority_required}

      # With verified AuthContext but no fs/read — still denied (not opened via params).
      grant!(principal, "arbor://action/pipeline/validate")

      denied =
        Validate.run(
          %{source_file: relative_dot, agent_id: "agent_spoofed"},
          run_context(principal, signer, workdir)
        )

      assert match?({:error, {:source_file_read_denied, _}}, denied)
    end
  end
end
