defmodule Arbor.Contracts.ContractTestDispatchTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbor.Contracts.Test, as: ContractTest

  @moduletag :fast
  @prefix ["--no-deps-check", "--warnings-as-errors", "--"]
  @kernel "packages/arbor_kernel/test/arbor/contracts/example_test.exs"
  @app "apps/arbor_security/test/arbor/security/contracts/example_test.exs"
  @support "apps/arbor_security/test/support/contracts/extra_test.exs"

  setup do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-contract-test-dispatch-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for path <- [
          "mix.exs",
          "packages/arbor_kernel/mix.exs",
          "apps/arbor_security/mix.exs",
          @kernel,
          @app,
          @support
        ] do
      write!(root, path)
    end

    %{root: root, apps: %{arbor_security: "apps/arbor_security"}}
  end

  test "mixed inventories keep Kernel-relative paths and both app contract layouts", ctx do
    assert {:ok, plan} =
             ContractTest.plan(@prefix ++ [@kernel, @app, @support], ctx.root, ctx.apps)

    assert plan.kernel_root == Path.join(ctx.root, "packages/arbor_kernel")
    assert plan.kernel_paths == ["test/arbor/contracts/example_test.exs"]
    assert plan.app_paths == Enum.sort([@app, @support])
    assert plan.app_count == 1
  end

  test "only the fixed owner options and nonempty inventory are admitted", ctx do
    for argv <- [
          [],
          @prefix,
          ["--warnings-as-errors", "--no-deps-check", "--", @kernel],
          ["--no-deps-check", "--warnings-as-errors", "--include", "external", "--", @kernel],
          @prefix ++ [@kernel, "--no-start"]
        ] do
      assert {:error, :invalid_contract_test_inventory} =
               ContractTest.plan(argv, ctx.root, ctx.apps)
    end
  end

  test "an existing test from another package or unselected app is refused", ctx do
    for path <- [
          "packages/arbor_custody/test/arbor/contracts/foreign_test.exs",
          "apps/arbor_orchestrator/test/arbor/contracts/foreign_test.exs",
          "apps/arbor_security/test/arbor/security/unrelated_test.exs"
        ] do
      write!(ctx.root, path)

      assert {:error, :invalid_contract_test_inventory} =
               ContractTest.plan(@prefix ++ [path], ctx.root, ctx.apps)
    end
  end

  test "a selected app needs its actual project marker", ctx do
    File.rm!(Path.join(ctx.root, "apps/arbor_security/mix.exs"))

    assert {:error, :invalid_contract_test_inventory} =
             ContractTest.plan(@prefix ++ [@app], ctx.root, ctx.apps)
  end

  test "canonical owner roots cannot be replaced with symlinks", ctx do
    kernel_root = Path.join(ctx.root, "packages/arbor_kernel")
    moved = Path.join(ctx.root, "moved_kernel")
    File.rename!(kernel_root, moved)
    File.ln_s!(moved, kernel_root)

    assert {:error, :invalid_contract_test_inventory} =
             ContractTest.plan(@prefix ++ [@kernel], ctx.root, ctx.apps)
  end

  test "a symlinked selected file cannot substitute another test", ctx do
    selected = Path.join(ctx.root, @kernel)
    replacement = write!(ctx.root, "replacement_test.exs")
    File.rm!(selected)
    File.ln_s!(replacement, selected)

    assert {:error, :invalid_contract_test_inventory} =
             ContractTest.plan(@prefix ++ [@kernel], ctx.root, ctx.apps)
  end

  test "traversal, line selectors, invalid bytes and noncanonical paths are refused", ctx do
    for path <- [
          "packages/arbor_kernel/test/arbor/contracts/../contracts/example_test.exs",
          "packages/arbor_kernel/test/arbor/contracts/./example_test.exs",
          @kernel <> ":12",
          @kernel <> " ",
          "/" <> @kernel,
          String.replace(@kernel, "/", "\\"),
          "packages/arbor_kernel/test/arbor/contracts/" <> <<255>> <> "_test.exs",
          "packages/arbor_kernel/test/arbor/contracts/\0_test.exs"
        ] do
      assert {:error, :invalid_contract_test_inventory} =
               ContractTest.plan(@prefix ++ [path], ctx.root, ctx.apps)
    end
  end

  defp write!(root, path) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "# owned dispatch fixture\n")
    full
  end
end
