# Micro-benchmarks for the preprocessor's pure/CPU paths.
#
#   mix run bench/preprocessor.exs
#
# Targets the deterministic, in-process work (no network): the module→action-name
# mapping and tier derivation. The LLM/embedding stages are I/O-bound and measured
# via telemetry spans at runtime, not here.

alias Arbor.Orchestrator.Preprocessor

# Warm the cached {module, name} registry so we measure steady-state lookup.
_ = Preprocessor.expand_modules(["Arbor.Actions.File"])

Benchee.run(
  %{
    "expand_modules/1 (single module → action names)" => fn ->
      Preprocessor.expand_modules(["Arbor.Actions.File"])
    end,
    "expand_modules/1 (5 modules, union+dedup)" => fn ->
      Preprocessor.expand_modules([
        "Arbor.Actions.File",
        "Arbor.Actions.Git",
        "Arbor.Actions.Shell",
        "Arbor.Actions.Memory",
        "Arbor.Actions.Code"
      ])
    end,
    "derive_tier/2" => fn ->
      Preprocessor.derive_tier(true, "MULTI_STEP")
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [fast_warning: false]
)
