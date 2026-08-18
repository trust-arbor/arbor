defmodule Mix.Tasks.Arbor.Packaging.SafeManagementSurfaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Commands.SafeManagementSurface
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.SafeManagementSurface, as: KernelSurface
  alias Mix.Tasks.Arbor.Packaging.SafeManagementSurface, as: Task

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parser rejects unknown, positional, repeated, conflicting, and negative input", %{
    root: root
  } do
    rel = write_receipt!(root)

    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--authorization-status", "verified"])

    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute([
               "--authorization-status=verified",
               "--operation",
               "list",
               "--receipt",
               rel
             ])

    assert {:error, {:arguments, :unknown_or_invalid_option}} = Task.execute(["--write"])
    assert {:error, {:arguments, :unexpected_positional}} = Task.execute(["list"])
    assert {:error, {:arguments, :missing_operation}} = Task.execute([])

    assert {:error, {:arguments, :missing_receipt}} =
             Task.execute(["--operation", "list"])

    assert {:error, {:arguments, :invalid_operation}} =
             Task.execute(["--operation", "purge", "--receipt", rel])

    assert {:error, {:arguments, {:repeated_option, :operation}}} =
             Task.execute(["--operation", "list", "--operation", "list", "--receipt", rel])

    assert {:error, {:arguments, {:conflicting_option, :operation}}} =
             Task.execute(["--operation", "list", "--operation", "revoke", "--receipt", rel])

    assert {:error, {:arguments, {:repeated_option, :receipt}}} =
             Task.execute(["--receipt", rel, "--receipt", rel, "--operation", "list"])

    assert {:error, {:arguments, {:conflicting_option, :json}}} =
             Task.execute([
               "--operation",
               "list",
               "--receipt",
               rel,
               "--json=true",
               "--json=false"
             ])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--operation", "list", "--receipt", rel, "--no-json"])

    assert {:error, {:arguments, {:invalid_boolean_switch, :json}}} =
             Task.execute(["--operation", "list", "--receipt", rel, "--json=false"])

    assert {:error, {:arguments, :invalid_argv}} = Task.execute([:operation])
  end

  test "production task rejects every runtime hook before execution" do
    assert {:error, {:production_task_forbids_runtime_hooks, [:authorization_status]}} =
             Task.execute(["--operation", "list", "--receipt", "x.json"],
               authorization_status: "verified"
             )

    assert {:error, {:production_task_forbids_runtime_hooks, [:candidate]}} =
             Task.execute(["--operation", "list", "--receipt", "x.json"], candidate: %{})

    assert {:error, :invalid_runtime_opts} =
             Task.execute(["--operation", "list", "--receipt", "x.json"], [:verified])
  end

  test "production Mix path with a valid fixture receipt still denies", %{root: root} do
    receipt = Envelope.fixture(:activation_receipt)
    rel = write_receipt!(root, receipt)

    assert {:ok, document} =
             Task.execute(["--root", root, "--operation", "list", "--receipt", rel])

    assert document["schema"] == KernelSurface.schema()
    assert document["authorization_status"] == "absent"
    assert document["decision"] == "denied"
    assert document["error"] == "authorization_absent"
    assert Envelope.error_code?(:activation, document["error"])
    assert document["effects"] == []
    assert document["architecture_status"] == "blocked"
    assert document["receipt"] == receipt

    expected_human =
      "safe-management-surface operation=list authorization_status=absent " <>
        "decision=denied error=authorization_absent architecture_status=blocked effects=0"

    assert {:ok, ^expected_human} = Task.render_report(document, false)
    refute expected_human =~ "ready"
    refute expected_human =~ "verified"

    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      output =
        capture_io(fn ->
          assert {:error, {:shutdown, 1}} = Task.finish_report(document, %{json: false})
        end)

      assert output =~ expected_human
    after
      Mix.shell(old)
    end

    assert Task.exit_reason(document) == {:shutdown, 1}

    admitted = %{document | "decision" => "admitted", "error" => nil}
    assert Task.exit_reason(admitted) == :ok

    inconsistent = %{document | "decision" => "admitted", "error" => "authorization_absent"}
    assert Task.exit_reason(inconsistent) == {:shutdown, 1}
    assert Task.exit_reason(%{"decision" => "denied"}) == {:shutdown, 1}
  end

  test "JSON output is the Core document and stays denied on the production path", %{
    root: root
  } do
    rel = write_receipt!(root)

    assert {:ok, document} =
             Task.execute([
               "--root",
               root,
               "--operation=list",
               "--receipt=" <> rel,
               "--json=true"
             ])

    assert document["decision"] == "denied"
    assert document["authorization_status"] == "absent"
    assert {:ok, first} = Task.render_report(document, true)
    assert {:ok, second} = Task.render_report(document, true)
    assert first == second
    refute String.contains?(first, "\n")

    assert {:ok, decoded} = Jason.decode(first)
    assert decoded["decision"] == "denied"
    assert decoded["authorization_status"] == "absent"
    assert decoded["architecture_status"] == "blocked"
    assert decoded["error"] == "authorization_absent"
  end

  test "path and argv hardening fail closed for traversal and oversized receipts", %{
    root: root
  } do
    write_receipt!(root)

    assert {:error, :receipt_path_escape} =
             Task.execute([
               "--root",
               root,
               "--operation",
               "list",
               "--receipt",
               "../outside.json"
             ])

    huge = "apps/arbor_commands/priv/packaging/huge.json"
    path = Path.join(root, huge)
    File.mkdir_p!(Path.dirname(path))
    max_receipt_bytes = SafeManagementSurface.max_receipt_bytes()
    {:ok, io} = File.open(path, [:write, :binary])

    try do
      assert {:ok, ^max_receipt_bytes} = :file.position(io, max_receipt_bytes)
      :ok = IO.binwrite(io, <<0>>)
    after
      File.close(io)
    end

    assert {:error, :receipt_too_large} =
             Task.execute(["--root", root, "--operation", "list", "--receipt", huge])
  end

  defp write_receipt!(root, receipt \\ Envelope.fixture(:activation_receipt)) do
    rel = "apps/arbor_commands/priv/packaging/activation_receipt.json"
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(receipt))
    rel
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-management-task-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real_root} = SafePath.resolve_real(root)
    real_root
  end
end
