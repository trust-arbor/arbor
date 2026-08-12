# Run from apps/arbor_agent with a separate build for each environment:
#
# ARBOR_DB=sqlite MIX_ENV=dev MIX_BUILD_PATH=../../_build/export-probe-dev \
#   ../../bin/mix run --no-start ../../scripts/verify_lifecycle_test_only_exports.exs
# SECRET_KEY_BASE=0000000000000000000000000000000000000000000000000000000000000000 \
#   ARBOR_DB=sqlite MIX_ENV=prod MIX_BUILD_PATH=../../_build/export-probe-prod \
#   ../../bin/mix run --no-start ../../scripts/verify_lifecycle_test_only_exports.exs

unless Mix.env() in [:dev, :prod] do
  IO.puts(:stderr, "expected MIX_ENV=dev or MIX_ENV=prod, got #{Mix.env()}")
  System.halt(2)
end

module = Arbor.Agent.Lifecycle

case Code.ensure_loaded(module) do
  {:module, ^module} -> :ok
  {:error, reason} -> raise "could not load #{inspect(module)}: #{inspect(reason)}"
end

unless function_exported?(module, :ordinary_start_effects, 3) do
  raise "#{inspect(module)}.ordinary_start_effects/3 is missing"
end

forbidden_exports = [
  ordinary_start_effects: 4,
  ordinary_start_effects_for_test_store: 4
]

unexpected =
  Enum.filter(forbidden_exports, fn {name, arity} ->
    function_exported?(module, name, arity)
  end)

case unexpected do
  [] ->
    IO.puts("verified #{Mix.env()} Lifecycle test-only exports are absent")

  exports ->
    IO.puts(:stderr, "unexpected #{Mix.env()} exports: #{inspect(exports)}")
    System.halt(1)
end
