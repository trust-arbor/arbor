defmodule Arbor.Contracts.AdmissionTest do
  @moduledoc """
  Fast admission proofs for AC-1, AC-2, AC-3, AC-6, and AC-11.

  Grandfather inventory is the dated 2026-08-10 CENSUS.md A/A2/B/D sections
  (exact 61 paths) with canonical row justifications from the AC-02 packet.
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Census
  alias Mix.Tasks.Arbor.Contracts.Census, as: CensusTask

  @moduletag :fast

  # Default admission mode for the live guard (AC-6). Do not flip to :enforce.
  @mode :warn

  # ---------------------------------------------------------------------------
  # Canonical dated CENSUS grandfather map (2026-08-10)
  # 21 A + 10 A2 + 7 B + 23 D = 61. Paths app-relative under lib/arbor/contracts/.
  # ---------------------------------------------------------------------------

  # Tier A (21)
  @tier_a [
    {"lib/arbor/contracts/session/behavior.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/coding/reconciliation_manifest.ex",
     "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/session/assistant_message.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/session/state.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/session/config.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/session/heartbeat_result.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/session/turn_authority.ex", "AC-03 evicts to arbor_orchestrator"},
    {"lib/arbor/contracts/llm/budget_snapshot.ex", "AC-04 evicts to arbor_ai"},
    {"lib/arbor/contracts/ai/response.ex", "AC-04 evicts to arbor_ai"},
    {"lib/arbor/contracts/ai/request.ex", "AC-04 evicts to arbor_ai"},
    {"lib/arbor/contracts/ai/runtime_profile.ex", "AC-04 evicts to arbor_ai"},
    {"lib/arbor/contracts/consensus/code_review_request.ex", "AC-05 evicts to arbor_actions"},
    {"lib/arbor/contracts/judge/rubric.ex", "AC-05 evicts to arbor_actions"},
    {"lib/arbor/contracts/consensus/events.ex", "AC-06 evicts to arbor_consensus"},
    {"lib/arbor/contracts/consensus/agent_mailbox.ex", "AC-06 evicts to arbor_consensus"},
    {"lib/arbor/contracts/security/reflex.ex", "AC-07 evicts to arbor_security"},
    {"lib/arbor/contracts/security/invocation_receipt.ex", "AC-07 evicts to arbor_security"},
    {"lib/arbor/contracts/trust/event.ex", "AC-07 evicts to arbor_trust"},
    {"lib/arbor/contracts/eval/outcome.ex", "AC-08 evicts to arbor_agent"},
    {"lib/arbor/contracts/agent/spec.ex", "AC-08 evicts to arbor_agent"},
    {"lib/arbor/contracts/capability_match.ex", "AC-08 evicts to arbor_common"}
  ]

  # Tier A2 (10)
  @tier_a2 [
    {"lib/arbor/contracts/coding/source_inventory.ex", "AC-12 pending"},
    {"lib/arbor/contracts/consensus/consensus_event.ex", "AC-12 pending"},
    {"lib/arbor/contracts/persistence/vector_receipt.ex", "AC-12 pending"},
    {"lib/arbor/contracts/llm/control_plane_support.ex", "AC-12 pending"},
    {"lib/arbor/contracts/llm/auth_provenance.ex", "AC-12 pending"},
    {"lib/arbor/contracts/consensus/invariants.ex", "AC-12 pending"},
    {"lib/arbor/contracts/security/signing_authority/validator.ex", "AC-12 pending"},
    {"lib/arbor/contracts/agent/config.ex", "AC-12 pending"},
    {"lib/arbor/contracts/judge/evidence.ex", "AC-12 pending"},
    {"lib/arbor/contracts/handler/scoped_context.ex", "AC-12 pending"}
  ]

  # Tier B (7)
  @tier_b [
    {"lib/arbor/contracts/libraries/cartographer.ex", "AC-09 review"},
    {"lib/arbor/contracts/consensus/protocol.ex", "AC-09 review"},
    {"lib/arbor/contracts/skill_library.ex", "AC-09 review"},
    {"lib/arbor/contracts/comms/response_router.ex", "AC-09 review"},
    {"lib/arbor/contracts/judge/evidence_producer.ex", "AC-09 review"},
    {"lib/arbor/contracts/handler/registry.ex", "AC-09 review"},
    {"lib/arbor/contracts/security/sanitizer.ex", "AC-09 review"}
  ]

  # Tier D (23)
  @tier_d [
    {"lib/arbor/contracts/checkpoint.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/signal/event.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/error.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/session/message.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/session/turn.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/session/context_key.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/persistence/vector_validation.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/ai/error.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/session/tool_call.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/agent/authority.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/memory/types.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/ai/resource_budget.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/session/adapter.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/agent/context.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/consensus/change_proposal.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/comms/question.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/healing/anomaly_queue.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/healing/fingerprint.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/comms/question_registry.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/handler/computable.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/handler/writeable.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/handler/composable.ex", "AC-10 blocked on runtime census"},
    {"lib/arbor/contracts/handler/compute_policy.ex", "AC-10 blocked on runtime census"}
  ]

  @grandfathered (@tier_a ++ @tier_a2 ++ @tier_b ++ @tier_d)
                 |> Map.new()

  # Canonical dated CENSUS preamble (verbatim).
  @dated_census_preamble """
  # `arbor_contracts` consumer census — 2026-08-10

  Generated from the umbrella at `HEAD` on 2026-08-10. **Do not hand-edit.**
  Regenerate with `./bin/mix arbor.contracts.census --format markdown` (AC-02 deliverable).

  ## Method

  Two independent counts per file under `apps/arbor_contracts/lib/arbor/contracts/`:

  - **External consumers** — umbrella apps *other than* `arbor_contracts` referencing any module
    the file declares, or a descendant of one. Decides **admissibility** (AC-1).
  - **Internal consumers** — other files *inside* `apps/arbor_contracts` (both `lib/` and `test/`)
    referencing the same. Decides **movability** (AC-11).

  Both counts expand brace aliases (`alias Arbor.Contracts.Security.{Taint, TaintEnvelope}`) before
  matching — 234 such sites exist and a naive regex misses all of them. A file's consumer set is the
  union across every module it declares; several files declare five.

  **These are different questions and conflating them is unsound.** A module with one external
  consumer is inadmissible; it is only *movable* if nothing left behind in L0 still needs it.
  13 of the 31 files that pass the admissibility test fail the movability test.

  **Known limitation:** static references only. A module reached solely by runtime `apply/3` or a
  config-injected atom shows as zero-consumer. This is why Tier D is blocked on
  `runtime-usage-census-and-performance-telemetry` and Tier A is not.
  """

  # Run the expensive live census once for all live proofs.
  setup_all do
    assert {:ok, report} = Census.run(mode: @mode, grandfathered: @grandfathered)

    if report.violations != [] do
      IO.puts(Census.format(report, :text))
    end

    {:ok, live: report, by_path: Map.new(report.entries, &{&1.path, &1})}
  end

  test "grandfather inventory is exact 61 CENSUS A/A2/B/D paths with dispositions" do
    assert length(@tier_a) == 21
    assert length(@tier_a2) == 10
    assert length(@tier_b) == 7
    assert length(@tier_d) == 23
    assert map_size(@grandfathered) == 61
    assert Census.default_grandfathered() == @grandfathered
    assert @mode == :warn

    expected =
      (@tier_a ++ @tier_a2 ++ @tier_b ++ @tier_d)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert Map.keys(@grandfathered) |> Enum.sort() == expected
    assert length(Enum.uniq(expected)) == 61
    assert Enum.all?(expected, &String.starts_with?(&1, "lib/arbor/contracts/"))

    # Canonical disposition strings from the dated census rows.
    justs = Map.values(@grandfathered) |> Enum.uniq() |> Enum.sort()

    assert "AC-03 evicts to arbor_orchestrator" in justs
    assert "AC-04 evicts to arbor_ai" in justs
    assert "AC-05 evicts to arbor_actions" in justs
    assert "AC-06 evicts to arbor_consensus" in justs
    assert "AC-07 evicts to arbor_security" in justs
    assert "AC-07 evicts to arbor_trust" in justs
    assert "AC-08 evicts to arbor_agent" in justs
    assert "AC-08 evicts to arbor_common" in justs
    assert "AC-09 review" in justs
    assert "AC-10 blocked on runtime census" in justs
    assert "AC-12 pending" in justs

    # Named live paths land in the correct dated sections.
    assert @grandfathered["lib/arbor/contracts/trust/event.ex"] ==
             "AC-07 evicts to arbor_trust"

    assert @grandfathered["lib/arbor/contracts/session/state.ex"] ==
             "AC-03 evicts to arbor_orchestrator"

    assert @grandfathered["lib/arbor/contracts/session/config.ex"] ==
             "AC-03 evicts to arbor_orchestrator"

    assert @grandfathered["lib/arbor/contracts/security/signing_authority/validator.ex"] ==
             "AC-12 pending"

    assert @grandfathered["lib/arbor/contracts/coding/source_inventory.ex"] == "AC-12 pending"
    assert @grandfathered["lib/arbor/contracts/handler/scoped_context.ex"] == "AC-12 pending"
  end

  # ---------------------------------------------------------------------------
  # AC-2 counting fixtures
  # ---------------------------------------------------------------------------

  describe "AC-2 consumer counting" do
    @tag spec: "AC-2"
    test "expands brace aliases (Taint/TaintEnvelope regression)" do
      source = """
      defmodule C do
        alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
      end
      """

      assert "Arbor.Contracts.Security.Taint" in Census.expand_brace_aliases(source)
      assert "Arbor.Contracts.Security.TaintEnvelope" in Census.expand_brace_aliases(source)

      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/security/taint.ex",
                    "defmodule Arbor.Contracts.Security.Taint do\nend\n"},
                   {"lib/arbor/contracts/security/taint_envelope.ex",
                    "defmodule Arbor.Contracts.Security.TaintEnvelope do\nend\n"}
                 ],
                 consumer_sources: [{"apps/arbor_security/lib/consumer.ex", source}],
                 registry_source: ""
               )

      by_path = Map.new(report.entries, &{&1.path, &1})

      assert by_path["lib/arbor/contracts/security/taint.ex"].external_consumers == [
               "arbor_security"
             ]

      assert by_path["lib/arbor/contracts/security/taint_envelope.ex"].external_consumers == [
               "arbor_security"
             ]
    end

    @tag spec: "AC-2"
    test "counts arbitrary-depth descendant module references" do
      assert Census.module_or_descendant_mentioned?(
               "alias Arbor.Contracts.Fixture.Parent.Child.Grand\n",
               "Arbor.Contracts.Fixture.Parent"
             )

      refute Census.module_or_descendant_mentioned?(
               "alias Arbor.Contracts.Fixture.ParentX\n",
               "Arbor.Contracts.Fixture.Parent"
             )

      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/parent.ex",
                    "defmodule Arbor.Contracts.Fixture.Parent do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_security/lib/u.ex",
                    "defmodule U do\n  alias Arbor.Contracts.Fixture.Parent.Child.Grand\nend\n"}
                 ],
                 registry_source: ""
               )

      e = hd(report.entries)
      assert e.external_consumers == ["arbor_security"]
      assert e.tier == :a
    end

    @tag spec: "AC-2"
    test "column-0 defmodule only; indented nested modules ignored" do
      source = """
      defmodule Arbor.Contracts.Fixture.Outer do
        defmodule Nested do
        end
      end
      """

      assert Census.extract_modules(source) == ["Arbor.Contracts.Fixture.Outer"]
    end

    @tag spec: "AC-2"
    test "unions every column-0 defmodule in a multi-module file" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/multi.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.MultiA do
                    end
                    defmodule Arbor.Contracts.Fixture.MultiB do
                    end
                    """}
                 ],
                 consumer_sources: [
                   {"apps/arbor_security/lib/u.ex",
                    """
                    defmodule U do
                      alias Arbor.Contracts.Fixture.MultiB
                    end
                    """}
                 ],
                 registry_source: ""
               )

      e = hd(report.entries)
      assert e.modules == ["Arbor.Contracts.Fixture.MultiA", "Arbor.Contracts.Fixture.MultiB"]
      assert e.external_consumers == ["arbor_security"]
      assert e.tier == :a
    end

    @tag spec: "AC-2"
    test "counts test refs and excludes own mirrored tests" do
      assert Census.own_mirrored_test?(
               "lib/arbor/contracts/fixture/solo.ex",
               "test/arbor/contracts/fixture/solo_test.exs"
             )

      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/solo.ex",
                    "defmodule Arbor.Contracts.Fixture.Solo do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_contracts/test/arbor/contracts/fixture/solo_test.exs",
                    "defmodule T do\n  alias Arbor.Contracts.Fixture.Solo\nend\n"},
                   {"apps/arbor_security/test/s_test.exs",
                    "defmodule S do\n  alias Arbor.Contracts.Fixture.Solo\nend\n"}
                 ],
                 registry_source: ""
               )

      e = hd(report.entries)
      assert e.external_consumers == ["arbor_security"]
      assert e.tier == :a
      refute "test/arbor/contracts/fixture/solo_test.exs" in e.internal_consumers
    end

    @tag spec: "AC-2"
    test "physical LOC counts blank lines" do
      source = "defmodule Arbor.Contracts.Fixture.Loc do\n\nend\n"
      assert Census.physical_loc(source) == 4
    end

    @tag spec: "AC-2"
    test "boundary-correct refs do not match module prefixes" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/cap.ex",
                    "defmodule Arbor.Contracts.Fixture.Cap do\nend\n"},
                   {"lib/arbor/contracts/fixture/capacity.ex",
                    "defmodule Arbor.Contracts.Fixture.Capacity do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_security/lib/x.ex",
                    "defmodule X do\n  alias Arbor.Contracts.Fixture.Capacity\nend\n"}
                 ],
                 registry_source: ""
               )

      by_path = Map.new(report.entries, &{&1.path, &1})

      assert by_path["lib/arbor/contracts/fixture/capacity.ex"].external_consumers ==
               ["arbor_security"]

      assert by_path["lib/arbor/contracts/fixture/cap.ex"].external_consumers == []
      assert by_path["lib/arbor/contracts/fixture/cap.ex"].tier == :d
    end
  end

  # ---------------------------------------------------------------------------
  # AC-1 / AC-02 tier table fixtures
  # ---------------------------------------------------------------------------

  describe "AC-1 admissibility and AC-02 tier table" do
    @tag spec: "AC-1,AC-3"
    test "api facades are tier c without multi-consumer proof" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/api/shell.ex",
                    """
                    defmodule Arbor.Contracts.API.Shell do
                      @callback run() :: :ok
                    end
                    """}
                 ],
                 consumer_sources: [],
                 registry_source: "",
                 mode: @mode
               )

      e = hd(report.entries)
      assert e.tier == :c
      assert e.callbacks == 1
      assert report.violations == []
      refute Census.failed?(report)
    end

    @tag spec: "AC-1,AC-3,AC-6"
    test "api paths without callbacks remain tier c but violate admission" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/api/empty.ex",
                    "defmodule Arbor.Contracts.API.Empty do\nend\n"}
                 ],
                 consumer_sources: [],
                 registry_source: ""
               )

      assert hd(report.entries).tier == :c
      assert report.violations == report.entries
    end

    @tag spec: "AC-2,AC-3"
    test "callbacks>0 yield tier b even with zero external consumers" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/beh.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.Beh do
                      @callback run() :: :ok
                    end
                    """}
                 ],
                 consumer_sources: [],
                 registry_source: ""
               )

      e = hd(report.entries)
      assert e.callbacks == 1
      assert e.tier == :b
    end

    @tag spec: "AC-2,AC-3"
    test "zero external and zero callbacks is tier d" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/orphan.ex",
                    "defmodule Arbor.Contracts.Fixture.Orphan do\nend\n"}
                 ],
                 consumer_sources: [],
                 registry_source: ""
               )

      assert hd(report.entries).tier == :d
    end

    @tag spec: "AC-1,AC-6"
    test "single external consumer violates unless grandfathered; enforce fails" do
      sources = [
        {"lib/arbor/contracts/fixture/one.ex", "defmodule Arbor.Contracts.Fixture.One do\nend\n"}
      ]

      consumers = [
        {"apps/arbor_memory/lib/m.ex",
         "defmodule M do\n  alias Arbor.Contracts.Fixture.One\nend\n"}
      ]

      assert {:ok, warn} =
               Census.run(
                 contract_sources: sources,
                 consumer_sources: consumers,
                 registry_source: "",
                 mode: :warn
               )

      assert hd(warn.entries).tier == :a
      assert length(warn.violations) == 1
      refute Census.failed?(warn)

      warn_output = Census.format(warn, :text)
      assert warn_output =~ "Violations:"
      assert warn_output =~ "lib/arbor/contracts/fixture/one.ex"

      assert {:ok, enforce} =
               Census.run(
                 contract_sources: sources,
                 consumer_sources: consumers,
                 registry_source: "",
                 mode: :enforce
               )

      assert Census.failed?(enforce)

      assert {:ok, gf} =
               Census.run(
                 contract_sources: sources,
                 consumer_sources: consumers,
                 registry_source: "",
                 mode: :enforce,
                 grandfathered: %{"lib/arbor/contracts/fixture/one.ex" => "AC-03"}
               )

      assert gf.violations == []
      refute Census.failed?(gf)
    end

    @tag spec: "AC-1,AC-3"
    test "two external consumers are tier shared" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/shared.ex",
                    "defmodule Arbor.Contracts.Fixture.Shared do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_security/lib/a.ex",
                    "defmodule A do\n  alias Arbor.Contracts.Fixture.Shared\nend\n"},
                   {"apps/arbor_trust/lib/b.ex",
                    "defmodule B do\n  alias Arbor.Contracts.Fixture.Shared\nend\n"}
                 ],
                 registry_source: ""
               )

      e = hd(report.entries)
      assert e.tier == :shared
      assert e.external_consumers == ["arbor_security", "arbor_trust"]
      assert report.violations == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC-11 movability / a vs a2
  # ---------------------------------------------------------------------------

  describe "AC-11 tiers and exemptions" do
    @tag spec: "AC-11"
    test "blocking internal consumer yields tier a2" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/base.ex",
                    "defmodule Arbor.Contracts.Fixture.Base do\nend\n"},
                   {"lib/arbor/contracts/fixture/user.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.User do
                      alias Arbor.Contracts.Fixture.Base
                    end
                    """}
                 ],
                 consumer_sources: [
                   {"apps/arbor_gateway/lib/g.ex",
                    "defmodule G do\n  alias Arbor.Contracts.Fixture.Base\nend\n"},
                   {"apps/arbor_contracts/lib/arbor/contracts/fixture/user.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.User do
                      alias Arbor.Contracts.Fixture.Base
                    end
                    """}
                 ],
                 registry_source: ""
               )

      base = Enum.find(report.entries, &(&1.path == "lib/arbor/contracts/fixture/base.ex"))
      assert "lib/arbor/contracts/fixture/user.ex" in base.internal_consumers
      assert base.tier == :a2
    end

    @tag spec: "AC-11"
    test "same-destination Tier A co-movers remain tier a after fixed-point" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/m1.ex",
                    "defmodule Arbor.Contracts.Fixture.M1 do\nend\n"},
                   {"lib/arbor/contracts/fixture/m2.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.M2 do
                      alias Arbor.Contracts.Fixture.M1
                    end
                    """}
                 ],
                 consumer_sources: [
                   {"apps/arbor_gateway/lib/g.ex",
                    """
                    defmodule G do
                      alias Arbor.Contracts.Fixture.M1
                      alias Arbor.Contracts.Fixture.M2
                    end
                    """},
                   {"apps/arbor_contracts/lib/arbor/contracts/fixture/m2.ex",
                    """
                    defmodule Arbor.Contracts.Fixture.M2 do
                      alias Arbor.Contracts.Fixture.M1
                    end
                    """}
                 ],
                 registry_source: ""
               )

      by_path = Map.new(report.entries, &{&1.path, &1})
      assert by_path["lib/arbor/contracts/fixture/m1.ex"].tier == :a
      assert by_path["lib/arbor/contracts/fixture/m2.ex"].tier == :a
    end

    @tag spec: "AC-11"
    test "registry file reference is not a blocking internal consumer" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/regged.ex",
                    "defmodule Arbor.Contracts.Fixture.Regged do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_gateway/lib/g.ex",
                    "defmodule G do\n  alias Arbor.Contracts.Fixture.Regged\nend\n"},
                   {"apps/arbor_contracts/lib/arbor/contracts.ex",
                    "defmodule Arbor.Contracts do\n  [Arbor.Contracts.Fixture.Regged]\nend\n"}
                 ],
                 registry_source: "Arbor.Contracts.Fixture.Regged"
               )

      e = hd(report.entries)
      assert e.in_registry
      assert "lib/arbor/contracts.ex" in e.internal_consumers
      assert e.tier == :a
    end

    @tag spec: "AC-2"
    test "internal consumers include test paths app-relative" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/fixture/base.ex",
                    "defmodule Arbor.Contracts.Fixture.Base do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_contracts/test/arbor/contracts/dependency_hierarchy_test.exs",
                    "defmodule H do\n  alias Arbor.Contracts.Fixture.Base\nend\n"},
                   {"apps/arbor_security/lib/s.ex",
                    "defmodule S do\n  alias Arbor.Contracts.Fixture.Base\nend\n"}
                 ],
                 registry_source: ""
               )

      base = hd(report.entries)
      assert "test/arbor/contracts/dependency_hierarchy_test.exs" in base.internal_consumers
      assert base.tier == :a2
    end
  end

  # ---------------------------------------------------------------------------
  # Formatters + mix task
  # ---------------------------------------------------------------------------

  describe "formatters and mix task" do
    @tag spec: "AC-2,AC-3"
    test "exact AC-02 fields; markdown preserves CENSUS preamble; text groups by tier" do
      assert {:ok, report} =
               Census.run(
                 contract_sources: [
                   {"lib/arbor/contracts/api/shell.ex",
                    """
                    defmodule Arbor.Contracts.API.Shell do
                      @callback run() :: :ok
                    end
                    """},
                   {"lib/arbor/contracts/fixture/solo.ex",
                    "defmodule Arbor.Contracts.Fixture.Solo do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_security/lib/x.ex",
                    "defmodule X do\n  alias Arbor.Contracts.Fixture.Solo\nend\n"}
                 ],
                 registry_source: "Arbor.Contracts.API.Shell",
                 now: ~U[2026-08-10 12:00:00Z]
               )

      e = Enum.find(report.entries, &(&1.path == "lib/arbor/contracts/api/shell.ex"))

      assert Map.keys(e) |> Enum.sort() ==
               [
                 :callbacks,
                 :external_consumers,
                 :in_registry,
                 :internal_consumers,
                 :loc,
                 :modules,
                 :path,
                 :tier
               ]

      assert e.tier == :c

      json = Census.format(report, :json)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_list(decoded["entries"])

      md = Census.format(report, :markdown, preamble: @dated_census_preamble)
      assert md =~ "# `arbor_contracts` consumer census — 2026-08-10"
      assert md =~ "Do not hand-edit"
      assert md =~ "runtime-usage-census-and-performance-telemetry"
      assert md =~ "## Inventory"
      assert md =~ "files /"
      assert md =~ "LOC"

      text = Census.format(report, :text)
      assert text =~ "### tier"
      assert text =~ "destination"
      assert text =~ "loc_by_tier:"
    end

    @tag spec: "AC-3,AC-6"
    test "comma tier filters and fail-on-violation mix wiring" do
      sources = [
        {"lib/arbor/contracts/api/a.ex", "defmodule Arbor.Contracts.API.A do\nend\n"},
        {"lib/arbor/contracts/fixture/b.ex", "defmodule Arbor.Contracts.Fixture.B do\nend\n"}
      ]

      consumers = [
        {"apps/arbor_security/lib/x.ex",
         "defmodule X do\n  alias Arbor.Contracts.Fixture.B\nend\n"}
      ]

      assert {:ok, report} =
               Census.run(
                 contract_sources: sources,
                 consumer_sources: consumers,
                 registry_source: "",
                 tier: "c,a"
               )

      assert report.contract_file_count == 2
      assert Enum.all?(report.entries, &(&1.tier in [:c, :a]))

      assert {:ok, enforce_report, text} =
               CensusTask.execute(["--fail-on-violation", "--format", "text"],
                 contract_sources: sources,
                 consumer_sources: consumers,
                 registry_source: ""
               )

      assert enforce_report.mode == :enforce
      assert text =~ "Arbor contracts census"
      assert Census.failed?(enforce_report)

      assert {:ok, grandfathered_report, _text} =
               CensusTask.execute(["--fail-on-violation", "--format", "text"],
                 contract_sources: [
                   {"lib/arbor/contracts/session/behavior.ex",
                    "defmodule Arbor.Contracts.Fixture.Grandfathered do\nend\n"}
                 ],
                 consumer_sources: [
                   {"apps/arbor_orchestrator/lib/consumer.ex",
                    "alias Arbor.Contracts.Fixture.Grandfathered\n"}
                 ],
                 registry_source: ""
               )

      refute Census.failed?(grandfathered_report)
    end
  end

  # ---------------------------------------------------------------------------
  # Live tree (single setup_all census)
  # ---------------------------------------------------------------------------

  describe "live tree census" do
    @tag spec: "AC-1,AC-2,AC-3,AC-6,AC-11"
    test "inventories tracked contracts with exact fields", %{live: report} do
      assert report.contract_file_count > 50
      assert report.mode == :warn
      refute Census.failed?(report)

      Enum.each(report.entries, fn e ->
        assert String.starts_with?(e.path, "lib/arbor/contracts/")
        assert is_list(e.modules)
        assert is_integer(e.loc) and e.loc >= 0
        assert is_list(e.external_consumers)
        assert is_list(e.internal_consumers)
        assert is_boolean(e.in_registry)
        assert is_integer(e.callbacks) and e.callbacks >= 0
        assert e.tier in Census.valid_tiers()

        Enum.each(e.internal_consumers, fn p ->
          assert String.starts_with?(p, "lib/") or String.starts_with?(p, "test/")
        end)
      end)

      api = Enum.filter(report.entries, &String.starts_with?(&1.path, "lib/arbor/contracts/api/"))
      assert api != []
      assert Enum.all?(api, &(&1.tier == :c))

      cap = Enum.find(report.entries, &(&1.path == "lib/arbor/contracts/security/capability.ex"))
      assert cap
      assert length(cap.external_consumers) >= 2
      assert cap.tier == :shared

      refute Enum.any?(report.entries, &String.contains?(&1.path, "contracts_census"))

      Enum.each(report.violations, fn e ->
        refute Map.has_key?(@grandfathered, e.path)
        refute e.tier == :shared
        refute String.starts_with?(e.path, "lib/arbor/contracts/api/")
      end)

      s = report.summary
      assert is_integer(s.tier_a)
      assert is_integer(s.tier_a2)
      assert is_integer(s.tier_b)
      assert is_integer(s.tier_d)
      assert is_integer(s.total_loc)

      md = Census.format(report, :markdown, preamble: @dated_census_preamble)
      assert md =~ "# `arbor_contracts` consumer census — 2026-08-10"
      assert md =~ "Do not hand-edit"
      assert md =~ "lib/arbor/contracts/security/capability.ex"
    end

    @tag spec: "AC-2,AC-3,AC-11"
    test "live: signing_authority/validator has 6 internals incl api/security and is a2", %{
      by_path: by_path
    } do
      e = by_path["lib/arbor/contracts/security/signing_authority/validator.ex"]
      assert e
      assert "arbor_security" in e.external_consumers
      assert e.tier == :a2
      assert length(e.internal_consumers) == 6
      assert "lib/arbor/contracts/api/security.ex" in e.internal_consumers
      assert "lib/arbor/contracts/security/signing_authority.ex" in e.internal_consumers
      assert "lib/arbor/contracts/security/signing_authority_bootstrap.ex" in e.internal_consumers
      assert "lib/arbor/contracts/security/signed_request.ex" in e.internal_consumers
      assert "lib/arbor/contracts/security/delivery_receipt.ex" in e.internal_consumers
      assert "lib/arbor/contracts/session/turn_authority.ex" in e.internal_consumers
    end

    @tag spec: "AC-2,AC-3,AC-11"
    test "live: coding/source_inventory includes dependency_hierarchy test and is a2", %{
      by_path: by_path
    } do
      e = by_path["lib/arbor/contracts/coding/source_inventory.ex"]
      assert e
      assert "arbor_actions" in e.external_consumers
      assert e.tier == :a2
      assert "test/arbor/contracts/dependency_hierarchy_test.exs" in e.internal_consumers
    end

    @tag spec: "AC-2,AC-3,AC-11"
    test "live: handler/scoped_context includes 4 behaviours and is a2", %{by_path: by_path} do
      e = by_path["lib/arbor/contracts/handler/scoped_context.ex"]
      assert e
      assert "arbor_orchestrator" in e.external_consumers
      assert e.tier == :a2

      behaviours = [
        "lib/arbor/contracts/handler/composable.ex",
        "lib/arbor/contracts/handler/computable.ex",
        "lib/arbor/contracts/handler/readable.ex",
        "lib/arbor/contracts/handler/writeable.ex"
      ]

      Enum.each(behaviours, fn p -> assert p in e.internal_consumers end)
      assert length(Enum.filter(e.internal_consumers, &String.contains?(&1, "handler/"))) >= 4
    end

    @tag spec: "AC-2,AC-3"
    test "live: trust/event is tier a and registered", %{by_path: by_path} do
      e = by_path["lib/arbor/contracts/trust/event.ex"]
      assert e
      assert e.tier == :a
      assert e.in_registry
      assert "arbor_trust" in e.external_consumers
    end

    @tag spec: "AC-2,AC-3,AC-11"
    test "live: session state/config are tier a co-movers", %{by_path: by_path} do
      state = by_path["lib/arbor/contracts/session/state.ex"]
      config = by_path["lib/arbor/contracts/session/config.ex"]
      assert state
      assert config
      assert state.tier == :a
      assert config.tier == :a
      assert "arbor_orchestrator" in state.external_consumers
      assert "arbor_orchestrator" in config.external_consumers
    end

    @tag spec: "AC-1,AC-6"
    test "warn is default; enforce fails only on ungrandfathered debt", %{live: warn} do
      refute Census.failed?(warn)

      assert {:ok, enforce} = Census.run(mode: :enforce, grandfathered: @grandfathered)

      if enforce.violations == [] do
        refute Census.failed?(enforce)
      else
        assert Census.failed?(enforce)

        Enum.each(enforce.violations, fn e ->
          refute Map.has_key?(@grandfathered, e.path)
          refute e.tier == :shared
        end)
      end
    end
  end
end
