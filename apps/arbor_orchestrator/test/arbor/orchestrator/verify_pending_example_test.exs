defmodule Arbor.Orchestrator.VerifyPendingExampleTest do
  @moduledoc """
  End-to-end runner for `specs/pipelines/security/verify-pending.dot` — the
  Gap 2 fan-out. Records two findings (one L1 that needs verification, one
  high-confidence L0 that does not), runs verify-pending, and asserts the
  selector picked only the L1 one and the map fanned `verify-finding` over it,
  annotating that finding with a verdict (and leaving the L0 one untouched).

  This proves the full wiring: select_findings_to_verify (deterministic gate) →
  map (item_key=finding_id) → graph.invoke verify-finding (self-contained,
  loads its own content) → annotate. Unit tests cover the gate; only a live run
  proves the fan-out plumbing + per-item subgraph invocation.

  Tagged `:integration_lm_studio` — skipped by default. Run manually (LM Studio
  up with a capable model loaded — Gemma 4 31B works):

      ARBOR_KEY=~/.claude/arbor-personal/claude_cli_mbp.arbor.key \
        mix test apps/arbor_orchestrator/test/arbor/orchestrator/verify_pending_example_test.exs \
        --only integration_lm_studio
  """

  use ExUnit.Case, async: false

  @moduletag :integration_lm_studio
  # The fan-out runs one finding × 3 sequential Gemma-31B skeptics (~5 min each).
  @moduletag timeout: 1_800_000

  alias Arbor.Actions.Security.FindingStore
  alias Arbor.Contracts.Security.{Capability, Finding, Identity, SignedRequest}
  alias Arbor.Gateway.Signer.ProxyCore

  @dot_path Path.expand("../../../specs/pipelines/security/verify-pending.dot", __DIR__)
  @default_key "~/.claude/arbor-personal/claude_cli_mbp.arbor.key"

  setup_all do
    original_flag = Application.get_env(:arbor_orchestrator, :discover_local_providers, true)
    Application.put_env(:arbor_orchestrator, :discover_local_providers, true)
    Arbor.LLM.Client.clear_default_client()

    for mod <- [Arbor.Security.Identity.Registry, Arbor.Security.Identity.NonceCache] do
      if Process.whereis(mod) == nil, do: {:ok, _} = mod.start_link([])
    end

    on_exit(fn ->
      Application.put_env(:arbor_orchestrator, :discover_local_providers, original_flag)
      Arbor.LLM.Client.clear_default_client()
    end)

    :ok
  end

  test "selects the L1 finding and fans verify-finding over it, skipping the L0" do
    key_path = (System.get_env("ARBOR_KEY") || @default_key) |> Path.expand()
    if not File.exists?(key_path), do: flunk("No arbor identity key at #{key_path}")

    {:ok, %{agent_id: agent_id, private_key: private_key}} =
      key_path |> File.read!() |> ProxyCore.parse_key_file()

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    {:ok, identity} = Identity.new(public_key: public_key, name: "verify-pending-example-test")
    assert identity.agent_id == agent_id
    # Idempotent: a sibling integration test in the same BEAM may have already
    # registered this same agent identity.
    case Arbor.Security.Identity.Registry.register(identity) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    signer = fn resource -> SignedRequest.sign(resource, agent_id, private_key) end

    for uri <- [
          "arbor://orchestrator/execute/**",
          "arbor://orchestrator/execute/llm_query",
          # The map node is a composition primitive — fanning out N handlers
          # requires an explicit dispatch grant (handler_schema P0-3).
          "arbor://orchestrator/map/dispatch",
          "arbor://action/security/**"
        ] do
      grant_capability(agent_id, uri)
    end

    dir = Path.join(System.tmp_dir!(), "verify_pending_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    # An L1 (LLM-discovered) finding — the gate selects this for verification.
    l1 =
      Finding.new(
        category: :fail_open_authz,
        title: "authorize/4 rescues to :ok (fail-open)",
        detector: %{layer: "L1", name: "diff_review"},
        confidence: %{score: 0.5},
        location: %{file: "apps/arbor_security/lib/authz.ex", function: "authorize/4", line: 42},
        invariant_violated: "authorize must fail closed",
        recommendation: %{approach: "Return {:error, reason} from the rescue clause."}
      )

    # A high-confidence deterministic L0 finding — the gate skips this.
    l0 =
      Finding.new(
        category: :other,
        title: "high-confidence deterministic finding",
        detector: %{layer: "L0", name: "auth_smells"},
        confidence: %{score: 0.9},
        location: %{file: "apps/x/lib/other.ex", function: "f/1", line: 7}
      )

    {:recorded, _} = FindingStore.record(l1, dir)
    {:recorded, _} = FindingStore.record(l0, dir)

    initial_values = %{
      "output_dir" => dir,
      "session.agent_id" => agent_id
    }

    logs_root =
      Path.join(System.tmp_dir!(), "verify_pending_logs_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               signer: signer,
               initial_values: initial_values,
               logs_root: logs_root
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    assert "select" in result.completed_nodes
    assert "map_verify" in result.completed_nodes

    # The selector picked exactly the L1 finding, and the map fanned over it
    # without per-item errors (regression guard: a dropped session.agent_id
    # silently failed every per-item subgraph and the map skipped it).
    assert result.context["exec.select.to_verify"] == [l1.id]
    assert result.context["map.map_verify.errors"] == "[]"

    # The L1 finding got an adversarial verdict annotation...
    l1_content = File.read!(Path.join(dir, l1.id <> ".md"))
    assert l1_content =~ "## Verification (adversarial)"
    assert l1_content =~ ~r/verdict: (refuted|confirmed) \(\d+\/3 skeptics refuted\)/

    # ...and the high-confidence L0 finding was skipped (never verified).
    l0_content = File.read!(Path.join(dir, l0.id <> ".md"))
    refute l0_content =~ "## Verification (adversarial)"
  end

  defp grant_capability(principal_id, resource_uri) do
    {:ok, cap} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true, source: "verify_pending_example_test"}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end
end
