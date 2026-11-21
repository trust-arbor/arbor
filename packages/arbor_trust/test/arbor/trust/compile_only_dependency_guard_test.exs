defmodule Arbor.Trust.CompileOnlyDependencyGuardTest do
  @moduledoc """
  A dependency declared `runtime: false` may be matched on but never called.

  Trust is a layer on Capabilities and declares it as an ordinary runtime
  dependency (2026-11-21; it used to be compile-only while making 79 live
  calls). Persistence stays compile-only so that a Trust peer does not load
  it. The two calls listed below are the event-store path, which only runs
  when the host has configured and started Persistence. Do not add to the
  list: route new needs through a configured port.

  The check reads compiled import tables, so aliases and `defdelegate` cannot
  hide a call.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  @compile_only [:arbor_persistence]
  @known_exceptions MapSet.new([
                      {Arbor.Trust.EventConverter, Arbor.Persistence.Event, :new, 4},
                      {Arbor.Trust.EventStore, Arbor.Persistence.EventLog.ETS, :append, 3}
                    ])

  test "Trust calls no compile-only dependency beyond the recorded exceptions" do
    {:ok, trust_modules} = :application.get_key(:arbor_trust, :modules)

    forbidden =
      for app <- @compile_only,
          _ = Application.load(app),
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules,
          into: MapSet.new(),
          do: module

    assert MapSet.size(forbidden) > 10

    calls =
      for module <- trust_modules,
          not exempt?(module),
          {target, function, arity} <- imports(module),
          MapSet.member?(forbidden, target),
          function != :__struct__,
          do: {module, target, function, arity}

    unexpected = Enum.reject(calls, &MapSet.member?(@known_exceptions, &1))

    assert unexpected == [],
           "Trust calls a compile-only dependency at runtime: #{inspect(unexpected)}"

    assert MapSet.new(calls) == @known_exceptions,
           "a recorded exception no longer exists; remove it from @known_exceptions"
  end

  test "Capabilities is a declared runtime dependency" do
    assert :arbor_capabilities in Application.spec(:arbor_trust, :applications)
    refute :arbor_persistence in Application.spec(:arbor_trust, :applications)
  end

  defp exempt?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Mix.Tasks.") or
      module.module_info(:compile)
      |> Keyword.get(:source, ~c"")
      |> List.to_string()
      |> String.contains?("/test/support/")
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
