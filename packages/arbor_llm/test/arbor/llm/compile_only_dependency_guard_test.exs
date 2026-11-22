defmodule Arbor.LLM.CompileOnlyDependencyGuardTest do
  @moduledoc """
  A dependency declared `runtime: false` may be matched on but never called.

  The LLM package declares Signals and Capabilities compile-only so that an
  LLM peer does not start either application. The six calls listed below were
  found when the package was adopted (2026-11-21). They are pure functions on
  taint, tool-failure and signing-authority contracts, and they only work
  because the composing host loads those applications. Do not add to the
  list: move the contract to the library that owns the caller, or go through
  a configured port.

  The check reads compiled import tables, so aliases and `defdelegate` cannot
  hide a call.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  @compile_only [:arbor_signals, :arbor_capabilities]
  @known_exceptions MapSet.new([
                      {Arbor.LLM.ToolLoop, Arbor.Signals.Taint, :for_llm_output, 1},
                      {Arbor.LLM.ToolLoop, Arbor.Signals.Taint, :propagate_taint, 1},
                      {Arbor.LLM.ToolLoop, Arbor.Contracts.Tool.CallFailure, :describe, 1},
                      {Arbor.LLM.ToolLoop, Arbor.Contracts.Tool.CallFailure,
                       :indeterminate_effect?, 1},
                      {Arbor.LLM.ToolLoop, Arbor.Contracts.Tool.CallFailure, :new!, 1},
                      {Arbor.Contracts.Session.TurnAuthority,
                       Arbor.Contracts.Security.SigningAuthority.Validator, :extract_attributes,
                       2}
                    ])

  test "LLM calls no compile-only dependency beyond the recorded exceptions" do
    {:ok, llm_modules} = :application.get_key(:arbor_llm, :modules)

    forbidden =
      for app <- @compile_only,
          _ = Application.load(app),
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules,
          into: MapSet.new(),
          do: module

    assert MapSet.size(forbidden) > 10

    calls =
      for module <- llm_modules,
          not exempt?(module),
          {target, function, arity} <- imports(module),
          MapSet.member?(forbidden, target),
          function != :__struct__,
          do: {module, target, function, arity}

    unexpected = Enum.reject(calls, &MapSet.member?(@known_exceptions, &1))

    assert unexpected == [],
           "LLM calls a compile-only dependency at runtime: #{inspect(unexpected)}"

    assert MapSet.new(calls) == @known_exceptions,
           "a recorded exception no longer exists; remove it from @known_exceptions"
  end

  test "Signals and Capabilities are not started with the LLM application" do
    applications = Application.spec(:arbor_llm, :applications)
    refute :arbor_signals in applications
    refute :arbor_capabilities in applications
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
