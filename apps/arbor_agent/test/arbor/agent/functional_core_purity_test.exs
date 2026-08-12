defmodule Arbor.Agent.FunctionalCorePurityTest do
  @moduledoc """
  Mechanical CRC purity guard for arbor_agent `*_core.ex` modules.

  Time and randomness are imperative-shell facts. Cores must not call them
  (C3C1a1: RuntimeRestoreAdmissionClaimCore must not mint tokens via
  `:crypto.strong_rand_bytes/1`). Deterministic `:crypto.hash/2` is permitted.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  # Patterns from the functional-core skill, plus randomness/crypto non-determinism.
  # GenServer.from/0 typespecs and comments may mention GenServer; forbid call sites.
  @forbidden [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.get_env/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/\bRepo\./,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/:crypto\.strong_rand_bytes/,
    ~r/:crypto\.rand_seed/,
    ~r/\bProcess\.(send|send_after|monitor|spawn)/,
    ~r/\bFile\.(read|write|open|rm|ls)/
  ]

  test "functional cores contain no impurity (time, randomness, IO, process)" do
    roots = [
      Path.expand("../../../lib", __DIR__),
      Path.expand("../../../../lib", __DIR__)
    ]

    paths =
      roots
      |> Enum.flat_map(fn root -> Path.wildcard(Path.join(root, "**/*_core.ex")) end)
      |> Enum.uniq()
      |> Enum.filter(&String.contains?(&1, "/arbor_agent/"))

    assert paths != [], "expected to discover arbor_agent *_core.ex files"

    # Explicitly cover the C3C1a1 claim core even if wildcard layout drifts.
    claim_core =
      Path.expand(
        "../../../lib/arbor/agent/runtime_restore_admission_claim_core.ex",
        __DIR__
      )

    assert File.exists?(claim_core), "missing RuntimeRestoreAdmissionClaimCore source"
    paths = Enum.uniq([claim_core | paths])

    for path <- paths do
      src = File.read!(path)

      # Strip purity-lint:allow annotated lines (sparingly used exceptions).
      src =
        src
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, "purity-lint:allow"))
        |> Enum.join("\n")

      for re <- @forbidden do
        refute Regex.match?(re, src),
               "impure pattern #{inspect(re.source)} found in #{Path.relative_to_cwd(path)}"
      end
    end
  end

  test "security regression: claim core has no mint_token and no strong_rand_bytes" do
    path =
      Path.expand(
        "../../../lib/arbor/agent/runtime_restore_admission_claim_core.ex",
        __DIR__
      )

    src = File.read!(path)
    refute src =~ "mint_token"
    refute src =~ "strong_rand_bytes"

    assert Code.ensure_loaded?(Arbor.Agent.RuntimeRestoreAdmissionClaimCore)
    refute function_exported?(Arbor.Agent.RuntimeRestoreAdmissionClaimCore, :mint_token, 0)

    # Deterministic hashing remains in-core (allowed purity policy).
    assert function_exported?(Arbor.Agent.RuntimeRestoreAdmissionClaimCore, :fingerprint, 5)
    assert function_exported?(Arbor.Agent.RuntimeRestoreAdmissionClaimCore, :mint, 2)
  end
end
