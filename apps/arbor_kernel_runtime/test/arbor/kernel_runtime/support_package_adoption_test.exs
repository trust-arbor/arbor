defmodule Arbor.KernelRuntime.SupportPackageAdoptionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @modules [
    Arbor.Common.Pagination.Cursor,
    Arbor.Common.SafeAtom,
    Arbor.Common.SafePath,
    Arbor.Common.SafePath.RootBinding,
    Arbor.Common.SafePath.TraversalError,
    Arbor.Common.SafePath.NativeReaderArtifact,
    Arbor.Common.SensitiveData
  ]

  test "safety helpers and their native artifact retain identities with one package owner" do
    package_modules = Application.spec(:arbor_support, :modules) || []
    host_modules = Application.spec(:arbor_kernel_runtime, :modules) || []

    assert MapSet.disjoint?(MapSet.new(package_modules), MapSet.new(host_modules))

    for module <- @modules do
      assert module in package_modules
      refute module in host_modules
      assert Application.get_application(module) == :arbor_support
    end
  end

  test "the passive support application has no runtime owner or first-party backedge" do
    assert :arbor_support in Application.spec(:arbor_kernel_runtime, :applications)
    assert Application.spec(:arbor_support, :mod) in [nil, []]
    assert Application.spec(:arbor_support, :registered) in [nil, []]
    assert Application.spec(:arbor_support, :optional_applications) in [nil, []]
    assert Application.spec(:arbor_support, :included_applications) in [nil, []]

    applications = Application.spec(:arbor_support, :applications) || []
    refute :boundary in applications

    refute Enum.any?(applications, fn app ->
             String.starts_with?(Atom.to_string(app), "arbor_")
           end)
  end

  test "the native reader compiler and C source belong only to the support package" do
    root = Path.expand("../../../../..", __DIR__)
    runtime_root = Path.join(root, "apps/arbor_kernel_runtime")
    support_root = Path.join(root, "packages/arbor_support")
    runtime_project = File.read!(Path.join(runtime_root, "mix.exs"))
    support_project = File.read!(Path.join(support_root, "mix.exs"))

    refute runtime_project =~ ":arbor_safe_path_reader"
    refute runtime_project =~ "Mix.Tasks.Compile.ArborSafePathReader"
    refute File.exists?(Path.join(runtime_root, "c_src/arbor_safe_path_reader.c"))

    assert support_project =~ ":arbor_safe_path_reader"
    assert support_project =~ "Mix.Tasks.Compile.ArborSafePathReader"
    assert File.regular?(Path.join(support_root, "c_src/arbor_safe_path_reader.c"))

    for filename <- ["pagination/cursor.ex", "safe_atom.ex", "safe_path.ex", "sensitive_data.ex"] do
      refute File.exists?(Path.join(runtime_root, "lib/arbor/common/#{filename}"))
      assert File.regular?(Path.join(support_root, "lib/arbor/common/#{filename}"))
    end

    refute File.exists?(Path.join(runtime_root, "test/arbor/common/pagination/cursor_test.exs"))
    assert File.regular?(Path.join(support_root, "test/arbor/common/pagination/cursor_test.exs"))
  end
end
