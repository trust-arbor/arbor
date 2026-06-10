defmodule Arbor.Orchestrator.VerifyFindingExampleTest do
  @moduledoc """
  End-to-end runner for `specs/pipelines/security/verify-finding.dot`. Loads the
  caller's arbor identity + signer, records a security finding in a temp store,
  runs the 3-skeptic adversarial verification against LM Studio, and asserts the
  finding got a verification annotation. Validates the full DOT plumbing
  (compute skeptics → transforms → aggregate exec action), which unit tests can't.

  Tagged `:integration_lm_studio` — skipped by default. Run manually (LM Studio up
  with a capable model loaded — Gemma 4 31B works):

      ARBOR_KEY=~/.claude/arbor-personal/claude_cli_mbp.arbor.key \
        mix test apps/arbor_orchestrator/test/arbor/orchestrator/verify_finding_example_test.exs \
        --only integration_lm_studio
  """

  use ExUnit.Case, async: false

  @moduletag :integration_lm_studio
  # 3 sequential Gemma-31B skeptics (reasoning model, 5 min each) — give room.
  @moduletag timeout: 1_200_000

  alias Arbor.Actions.Security.FindingStore
  alias Arbor.Contracts.Security.{Capability, Finding, Identity, SignedRequest}
  alias Arbor.Gateway.Signer.ProxyCore

  @dot_path Path.expand("../../../specs/pipelines/security/verify-finding.dot", __DIR__)
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

  test "verifies a finding end-to-end and annotates it with a verdict" do
    key_path = (System.get_env("ARBOR_KEY") || @default_key) |> Path.expand()
    if not File.exists?(key_path), do: flunk("No arbor identity key at #{key_path}")

    {:ok, %{agent_id: agent_id, private_key: private_key}} =
      key_path |> File.read!() |> ProxyCore.parse_key_file()

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    {:ok, identity} = Identity.new(public_key: public_key, name: "verify-finding-example-test")
    assert identity.agent_id == agent_id
    :ok = Arbor.Security.Identity.Registry.register(identity)

    signer = fn resource -> SignedRequest.sign(resource, agent_id, private_key) end

    for uri <- [
          "arbor://orchestrator/execute/**",
          "arbor://orchestrator/execute/llm_query",
          "arbor://actions/execute/**"
        ] do
      grant_capability(agent_id, uri)
    end

    # Record a finding in a temp store; verification will annotate it there.
    dir = Path.join(System.tmp_dir!(), "verify_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    finding =
      Finding.new(
        category: :dependency_risk,
        title: "Git dependency `jido_sandbox` is not pinned to an immutable ref/tag",
        detector: %{layer: "L0b", name: "dependency_scan"},
        confidence: %{score: 0.6},
        location: %{file: "mix.exs", function: "deps/0"},
        invariant_violated:
          "Git deps must be pinned to a ref/tag; a branch floats with upstream.",
        recommendation: %{approach: "Pin jido_sandbox to a ref instead of branch: \"main\"."}
      )

    {:recorded, _} = FindingStore.record(finding, dir)

    initial_values = %{
      "finding_content" => Finding.to_markdown(finding),
      "finding_id" => finding.id,
      "output_dir" => dir,
      "session.agent_id" => agent_id
    }

    logs_root = Path.join(System.tmp_dir!(), "verify_logs_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               signer: signer,
               initial_values: initial_values,
               logs_root: logs_root
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    assert "skeptic_1" in result.completed_nodes
    assert "skeptic_3" in result.completed_nodes
    assert "aggregate" in result.completed_nodes

    # The aggregate node returns the verdict; the finding file is annotated.
    content = File.read!(Path.join(dir, finding.id <> ".md"))
    assert content =~ "## Verification (adversarial)"
    assert content =~ ~r/verdict: (refuted|confirmed) \(\d+\/3 skeptics refuted\)/
  end

  defp grant_capability(principal_id, resource_uri) do
    {:ok, cap} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true, source: "verify_finding_example_test"}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end
end
