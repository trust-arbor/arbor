defmodule Arbor.Orchestrator.ContextTaintAdmissionSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Contracts.Security.Taint

  @moduletag :fast
  @moduletag :security_regression

  setup do
    root =
      Path.join(System.tmp_dir!(), "engine_taint_admission_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "security regression: content scan cannot lower inherited sensitivity at provider admission",
       %{root: root} do
    dot =
      "digraph Data { start [shape=Mdiamond] work [type=compute, simulate=true, llm_provider=openai, sensitivity=restricted] done [shape=Msquare] start -> work -> done }"

    opts = [
      logs_root: root,
      workdir: root,
      resumable: false,
      initial_values: %{"last_response" => "innocuous text"}
    ]

    {:ok, allowed} = Arbor.Orchestrator.run(dot, opts)
    assert allowed.final_outcome.status == :success

    {:ok, denied} =
      Arbor.Orchestrator.run(
        dot,
        Keyword.put(opts, :initial_taint, %{
          "last_response" => %Taint{level: :derived, sensitivity: :restricted}
        })
      )

    assert denied.final_outcome.status == :fail
    assert denied.final_outcome.failure_reason =~ "restricted"
  end

  test "security regression: actual sanitizer evidence survives classification before a file effect",
       %{root: root} do
    dot = """
    digraph Sanitize {
      start [shape=Mdiamond]
      clean [type=sanitize, source_key=path, output_key=last_response, sanitize=path_traversal, allowed_root="#{root}"]
      write [type=write, target=file, content_key=content, output="result.txt"]
      done [shape=Msquare]
      start -> clean -> write -> done
    }
    """

    {:ok, result} =
      Arbor.Orchestrator.run(dot,
        workdir: root,
        logs_root: Path.join(root, "logs"),
        resumable: false,
        initial_values: %{"path" => "result.txt", "content" => "verified"}
      )

    assert result.final_outcome.status == :success
    assert File.read!(Path.join(root, "result.txt")) == "verified"
  end

  test "security regression: an unlabeled copy cannot borrow evidence from different declared bytes",
       %{root: root} do
    dot = """
    digraph Mixed {
      start [shape=Mdiamond]
      copy [type=transform, transform=identity, source_key=plain, context_keys=sanitized, output_key=copied]
      done [shape=Msquare]
      start -> copy -> done
    }
    """

    label = %Taint{
      level: :derived,
      sensitivity: :restricted,
      sanitizations: 8,
      confidence: :verified
    }

    opts = [
      workdir: root,
      logs_root: root,
      resumable: false,
      initial_values: %{"plain" => 42, "sanitized" => "different bytes"},
      initial_taint: %{"sanitized" => label}
    ]

    assert {:ok, result} = Arbor.Orchestrator.run(dot, opts)
    assert result.final_outcome.status == :success
    assert result.context["copied"] == 42
    assert result.taint["copied"].sensitivity == :restricted
    assert result.taint["copied"].sanitizations == 0
    assert result.taint["copied"].confidence == :unverified

    # The unchanged, actually attested source still retains its own evidence.
    assert {:ok, exact} =
             Arbor.Orchestrator.run(
               String.replace(dot, "source_key=plain", "source_key=sanitized"),
               opts
             )

    assert exact.context["copied"] == "different bytes"
    assert exact.taint["copied"].sanitizations == 8
    assert exact.taint["copied"].confidence == :verified
  end

  test "security regression: numerically equal values cannot borrow exact-copy evidence", %{
    root: root
  } do
    dot = """
    digraph StrictCopy {
      start [shape=Mdiamond]
      copy [type=transform, transform=json_extract, source_key=payload, context_keys=attested, output_key=copied, expression=value]
      done [shape=Msquare]
      start -> copy -> done
    }
    """

    label = %Taint{
      level: :derived,
      sensitivity: :restricted,
      sanitizations: 8,
      confidence: :verified
    }

    for {attested, changed} <- [{1, 1.0}, {%{"nested" => 1}, %{"nested" => 1.0}}, {[1], [1.0]}] do
      opts = [
        workdir: root,
        logs_root: root,
        resumable: false,
        initial_values: %{"payload" => %{"value" => changed}, "attested" => attested},
        initial_taint: %{"attested" => label}
      ]

      assert {:ok, result} = Arbor.Orchestrator.run(dot, opts)
      assert result.final_outcome.status == :success
      assert result.context["copied"] === changed
      assert result.taint["copied"].sensitivity == :restricted
      assert result.taint["copied"].sanitizations == 0
      assert result.taint["copied"].confidence == :unverified

      exact_opts =
        Keyword.put(opts, :initial_values, %{
          "payload" => %{"value" => attested},
          "attested" => attested
        })

      assert {:ok, exact} = Arbor.Orchestrator.run(dot, exact_opts)
      assert exact.context["copied"] === attested
      assert exact.taint["copied"].sanitizations == 8
      assert exact.taint["copied"].confidence == :verified
    end
  end

  test "security regression: context replacement cannot reuse old sanitizer or confidence evidence" do
    alias Arbor.Orchestrator.Engine.Context

    label = %Taint{
      level: :derived,
      sensitivity: :restricted,
      sanitizations: 8,
      confidence: :verified
    }

    original = Context.new(%{"value" => "first"}, taint: %{"value" => label})

    for updated <- [
          Context.set(original, "value", "second"),
          Context.set(original, "value", "second", "different_producer"),
          Context.apply_updates(original, %{"value" => "second"}),
          Context.apply_updates(original, %{"value" => "second"}, "different_producer")
        ] do
      actual = Context.taint_label(updated, "value")
      assert actual.sanitizations == 0
      assert actual.confidence == :unverified
      assert actual.sensitivity == :restricted
    end
  end

  test "security regression: transformed bytes cannot inherit a sanitizer bit", %{root: root} do
    dot = """
    digraph Changed {
      start [shape=Mdiamond]
      clean [type=sanitize, source_key=path, output_key=last_response, sanitize=path_traversal, allowed_root="#{root}"]
      change [type=transform, transform=template, source_key=last_response, output_key=last_response, expression="../{value}"]
      write [type=write, target=file, content_key=content, output="must-not-exist.txt"]
      done [shape=Msquare]
      start -> clean -> change -> write -> done
    }
    """

    {:ok, result} =
      Arbor.Orchestrator.run(dot,
        workdir: root,
        logs_root: Path.join(root, "logs"),
        resumable: false,
        initial_values: %{"path" => "result.txt", "content" => "must not write"}
      )

    assert result.final_outcome.status == :fail
    assert result.taint["last_response"].sanitizations == 0
    assert result.taint["last_response"].confidence == :unverified
    refute File.exists?(Path.join(root, "must-not-exist.txt"))
  end

  test "security regression: scanned secret risk survives transformation and denies public provider",
       %{root: root} do
    dot = """
    digraph Scan {
      start [shape=Mdiamond]
      change [type=transform, source_key=secret, output_key=last_response, transform=template, expression="opaque summary"]
      model [type=compute, simulate=true, llm_provider=openai, sensitivity=restricted]
      done [shape=Msquare]
      start -> change -> model -> done
    }
    """

    {:ok, result} =
      Arbor.Orchestrator.run(dot,
        logs_root: root,
        workdir: root,
        resumable: false,
        initial_values: %{"secret" => ~s(password="example-secret-value")}
      )

    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason =~ "restricted"
    assert result.taint["secret"].sensitivity == :restricted
    assert result.taint["last_response"].sensitivity == :restricted
    assert result.taint["last_response"].sanitizations == 0
    assert result.taint["last_response"].confidence == :unverified
  end

  test "security regression: handler receives scanned context before transforming, and innocuous origin remains derived",
       %{root: root} do
    dot = """
    digraph Scan {
      start [shape=Mdiamond]
      change [type=transform, source_key=secret, output_key=last_response, transform=template, expression="{ctx.__data_sensitivity__}"]
      done [shape=Msquare]
      start -> change -> done
    }
    """

    {:ok, result} =
      Arbor.Orchestrator.run(dot,
        logs_root: root,
        workdir: root,
        resumable: false,
        initial_values: %{"secret" => ~s(password="example-secret-value")}
      )

    assert result.final_outcome.status == :success
    assert result.context["last_response"] == "restricted"
    assert result.taint["last_response"].sensitivity == :restricted

    public = String.replace(dot, "{ctx.__data_sensitivity__}", "innocuous output")

    {:ok, result} =
      Arbor.Orchestrator.run(public,
        logs_root: Path.join(root, "public"),
        workdir: root,
        resumable: false,
        initial_values: %{"secret" => "innocuous input"}
      )

    assert result.taint["last_response"].level == :derived
    assert result.taint["last_response"].confidence == :unverified
    assert result.taint["last_response"].sanitizations == 0
  end
end
