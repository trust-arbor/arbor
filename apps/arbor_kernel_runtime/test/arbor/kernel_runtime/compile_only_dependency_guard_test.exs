defmodule Arbor.KernelRuntime.CompileOnlyDependencyGuardTest do
  @moduledoc """
  Kernel Runtime declares `arbor_capabilities` with `runtime: false`: a runtime
  edge would deadlock boot, because Capabilities asks its host to start Kernel
  Runtime. A compile-only dependency may be matched on (struct patterns) but
  must never be called, or the call fails in any release or peer that starts
  Kernel Runtime without Capabilities loaded.

  The check reads the compiled import table of every Kernel Runtime module, so
  aliases, `defdelegate` and captured functions cannot hide a call.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  # Mix tasks run in a project where every dependency is loaded, and test
  # support modules are only compiled into the test build.
  defp exempt?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Mix.Tasks.") or
      module.module_info(:compile)
      |> Keyword.get(:source, ~c"")
      |> List.to_string()
      |> String.contains?("/test/support/")
  end

  test "no Kernel Runtime module calls a Capabilities module at runtime" do
    _ = Application.load(:arbor_capabilities)
    {:ok, runtime_modules} = :application.get_key(:arbor_kernel_runtime, :modules)
    {:ok, capability_modules} = :application.get_key(:arbor_capabilities, :modules)
    forbidden = MapSet.new(capability_modules)

    assert MapSet.size(forbidden) > 50

    calls =
      for module <- runtime_modules,
          not exempt?(module),
          {target, function, arity} <- imports(module),
          MapSet.member?(forbidden, target),
          # Struct expansion and pattern matching compile to this lookup only
          # when the struct module is absent at compile time; a guarded
          # `is_struct/2` needs no call at all.
          function not in [:__struct__] do
        "#{inspect(module)} calls #{inspect(target)}.#{function}/#{arity}"
      end

    assert calls == [],
           "Kernel Runtime calls a compile-only dependency at runtime. Go through the " <>
             "configured security module instead:\n" <> Enum.join(Enum.sort(calls), "\n")
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _ -> flunk("could not read the import table of #{inspect(module)}")
    end
  end
end
