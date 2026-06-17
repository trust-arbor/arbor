defmodule Arbor.Orchestrator.L1DiffReviewExampleTest do
  @moduledoc """
  End-to-end runner for `specs/pipelines/security/l1-diff-review.dot`. Feeds a
  diff containing a planted, obvious security issue (a fail-open authorize + a
  logged secret), runs the L1 LLM review against LM Studio, and asserts at least
  one Finding was recorded. Validates the full plumbing (compute review →
  transform → exec record action → store) the unit tests can't reach.

  Tagged `:integration_lm_studio` — skipped by default:

      ARBOR_KEY=~/.claude/arbor-personal/claude_cli_mbp.arbor.key \
        mix test apps/arbor_orchestrator/test/arbor/orchestrator/l1_diff_review_example_test.exs \
        --only integration_lm_studio
  """

  use ExUnit.Case, async: false

  @moduletag :integration_lm_studio
  @moduletag timeout: 600_000

  alias Arbor.Contracts.Security.{Capability, Identity, SignedRequest}
  # Parse the agent key file via the canonical home in arbor_security
  # (Arbor.Gateway.Signer.ProxyCore.parse_key_file/1 is just a defdelegate to
  # this). arbor_gateway is NOT a dep of arbor_orchestrator, so ProxyCore is
  # unreachable in the isolated per-app test BEAM; Arbor.Security.KeyFile is
  # reachable transitively via the arbor_actions dep.
  alias Arbor.Security.KeyFile

  @dot_path Path.expand("../../../specs/pipelines/security/l1-diff-review.dot", __DIR__)
  @default_key "~/.claude/arbor-personal/claude_cli_mbp.arbor.key"

  # A diff with two unmistakable, newly-introduced issues: a fail-open authorize
  # and a logged secret. A capable model should flag at least one.
  @planted_diff """
  diff --git a/lib/arbor/demo/auth.ex b/lib/arbor/demo/auth.ex
  index 1111111..2222222 100644
  --- a/lib/arbor/demo/auth.ex
  +++ b/lib/arbor/demo/auth.ex
  @@ -10,3 +10,14 @@ defmodule Arbor.Demo.Auth do
  +  def authorize(agent_id, resource) do
  +    check_capability(agent_id, resource)
  +  rescue
  +    _ -> :ok
  +  catch
  +    :exit, _ -> :ok
  +  end
  +
  +  def login(user, password, token) do
  +    Logger.info("login: user=\#{user} password=\#{password} token=\#{token}")
  +    {:ok, token}
  +  end
  """

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

  test "reviews a diff and records a finding for the planted issue" do
    key_path = (System.get_env("ARBOR_KEY") || @default_key) |> Path.expand()
    if not File.exists?(key_path), do: flunk("No arbor identity key at #{key_path}")

    {:ok, %{agent_id: agent_id, private_key: private_key}} =
      key_path |> File.read!() |> KeyFile.parse()

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    {:ok, identity} = Identity.new(public_key: public_key, name: "l1-diff-review-example-test")
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

    dir = Path.join(System.tmp_dir!(), "l1_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    logs_root = Path.join(System.tmp_dir!(), "l1_logs_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(logs_root)
    end)

    initial_values = %{
      "diff" => @planted_diff,
      "git_sha" => "testsha",
      "output_dir" => dir,
      "session.agent_id" => agent_id
    }

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               signer: signer,
               initial_values: initial_values,
               logs_root: logs_root
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    assert "review" in result.completed_nodes
    assert "record" in result.completed_nodes

    # The LLM should have flagged at least one of the planted issues, recorded
    # as a finding file in the temp store.
    recorded = Path.wildcard(Path.join(dir, "sec-finding_*.md"))

    assert recorded != [],
           "expected at least one L1 finding recorded for the planted fail-open/secret diff"
  end

  defp grant_capability(principal_id, resource_uri) do
    {:ok, cap} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true, source: "l1_diff_review_example_test"}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end
end
