defmodule Arbor.Orchestrator.EngineCheckpointPoisoningTest do
  @moduledoc """
  Adversarial: a hand-crafted checkpoint.json with poisoned context
  causes engine resume to adopt the attacker's chosen state verbatim.
  No HMAC verification fires because no production caller passes
  `:hmac_secret` to `Checkpoint.load/2`.

  ## Threat model — what actually escalates

  An attacker who can write `checkpoint.json` (e.g. an agent with a
  shell-write capability) can replace `context_values` with anything.
  On resume, the engine reapplies the file verbatim — no signature,
  no integrity check, no comparison against the resumer's identity.

  **The naive "agent_id swap" escalation does NOT work in production.**
  When ExecHandler later reads `session.agent_id` from the poisoned
  context and calls `ActionsExecutor.execute(name, args, workdir,
  agent_id: <poisoned>, signer: <resumer>)`, the action-layer auth
  chain catches the mismatch:

    `Arbor.Actions.authorize_and_execute` sets `verify_identity: true`
    whenever a signed_request is present →
    `AuthDecision.do_verify_signed_request` recovers `verified_id`
    from the signature (the *resumer's* identity, not the poisoned
    id) → `check_identity_binding(verified_id, principal_id)` rejects
    with `{:error, {:identity_mismatch, ...}}`.

  So the agent_id swap fails downstream IF:
    - the resumer passes `:signer` opt to `Engine.run/2`, AND
    - `Arbor.Security.Config.identity_verification_enabled?/0` is true.

  The escalation succeeds ONLY when both safeguards are off (dev/test
  default, unsigned CLI runs). That's still a real failure surface,
  but narrower than a single-flaw bypass.

  ## What the tests pin

  1. The engine adopts poisoned `context_values` verbatim on resume.
     (True. Direct consequence of `state_from_checkpoint/2`.)
  2. `Checkpoint.load/2` accepts ANY payload when no `hmac_secret`
     is passed. (True. `maybe_verify(decoded, nil) -> {:ok, decoded}`.)
  3. The HMAC machinery itself works when `hmac_secret` IS passed.
     (Confirms the fix is "wire it in by default", not "build it.")

  Filed as:
    `.arbor/roadmap/0-inbox/security-checkpoints-unverified-by-default.md`
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_known_gap

  alias Arbor.Orchestrator.Engine.Checkpoint

  # Minimal DOT: a single `function` exec node that captures the
  # agent_id the engine resolved from context. We use `target=function`
  # because it lets us inject a closure that reads the context directly
  # — no Arbor.Actions runtime needed.
  @capture_dot """
  digraph CaptureAgentId {
    graph [goal="capture engine-resolved agent_id at runtime"]
    start [shape=Mdiamond]
    capture [type="exec", target="function"]
    done [shape=Msquare]
    start -> capture -> done
  }
  """

  defp logs_root do
    Path.join(System.tmp_dir!(), "arbor_ckpt_poison_#{System.unique_integer([:positive])}")
  end

  # Hand-craft a checkpoint.json whose context_values pre-loads the
  # session.agent_id to whatever the attacker wants. The engine's
  # resume path (Engine.initial_state/3 → state_from_checkpoint/2)
  # does Context.new(checkpoint.context_values), so this value lands
  # in context unchanged.
  defp write_poisoned_checkpoint(path, %{
         current_node: current_node,
         completed: completed,
         poison: poison
       }) do
    File.mkdir_p!(Path.dirname(path))

    payload = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "run_id" => "poisoned_run_" <> Integer.to_string(System.unique_integer([:positive])),
      "graph_hash" => nil,
      "current_node" => current_node,
      "completed_nodes" => completed,
      "node_retries" => %{},
      "context_values" => poison,
      "node_outcomes" => %{},
      "context_lineage" => %{},
      "pipeline_started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content_hashes" => %{},
      "pending_intents" => %{},
      "execution_digests" => %{}
    }

    File.write!(path, Jason.encode!(payload))
    :ok
  end

  test "with identity_private_key, resume REJECTS unsigned poisoned checkpoint (security regression)" do
    # SECURITY REGRESSION TEST per CLAUDE.md — fails on HEAD~1, passes on HEAD.
    # When the resumer supplies identity_private_key, the engine derives a
    # checkpoint HMAC secret via HKDF (Arbor.Security.Crypto.derive_key).
    # Checkpoint.load then requires the payload's __hmac to match.
    # An attacker-crafted unsigned checkpoint has no __hmac → verify/3
    # returns {:error, :tampered} → resume fails closed.
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    write_poisoned_checkpoint(ckpt_path, %{
      current_node: "start",
      completed: ["start"],
      poison: %{
        "session.agent_id" => "agent_admin",
        "trust_tier" => "veteran"
      }
    })

    private_key = :crypto.strong_rand_bytes(32)

    result =
      Arbor.Orchestrator.run(@capture_dot,
        logs_root: root,
        resume_from: ckpt_path,
        authorization: false,
        identity_private_key: private_key,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    assert {:error, _reason} = result,
           "Engine accepted an unsigned poisoned checkpoint even with " <>
             "identity_private_key provided. Got: #{inspect(result)}"
  end

  test "LEGACY: without identity_private_key, engine still adopts poisoned context (transition gap)" do
    # Documents the unchanged-by-design legacy path. Callers that don't
    # pass identity_private_key still get the silent fail-open. Closing
    # this fully requires every caller to pass identity (a broader
    # migration tracked in the roadmap follow-up). The fact that this
    # test STILL passes is the gap; the test above documents what works
    # when callers opt in.
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    write_poisoned_checkpoint(ckpt_path, %{
      current_node: "start",
      completed: ["start"],
      poison: %{
        "session.agent_id" => "agent_admin",
        "trust_tier" => "veteran"
      }
    })

    {:ok, run_result} =
      Arbor.Orchestrator.run(@capture_dot,
        logs_root: root,
        resume_from: ckpt_path,
        authorization: false,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    assert run_result.context["session.agent_id"] == "agent_admin"
    assert run_result.context["trust_tier"] == "veteran"
  end

  test "Checkpoint.load accepts ANY JSON shape when no hmac_secret is passed" do
    # Even more direct: bypass the engine entirely and just call
    # Checkpoint.load. Whatever the file says, you get back. No
    # signature check. No allowlist of expected keys. No identity
    # binding.
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    write_poisoned_checkpoint(ckpt_path, %{
      current_node: "anything",
      completed: ["start", "anything"],
      poison: %{
        "session.agent_id" => "agent_admin",
        "session.trust_score" => 100,
        "secret.api_key" => "leaked_from_a_previous_run",
        "session.role" => "admin"
      }
    })

    assert {:ok, checkpoint} = Checkpoint.load(ckpt_path)

    # The forged context values come through unchanged. The Checkpoint
    # module doesn't validate, normalize, or compare against any
    # baseline.
    assert checkpoint.context_values["session.agent_id"] == "agent_admin"
    assert checkpoint.context_values["session.trust_score"] == 100
    assert checkpoint.context_values["secret.api_key"] == "leaked_from_a_previous_run"
    assert checkpoint.context_values["session.role"] == "admin"
  end

  test "Checkpoint.load WITH hmac_secret correctly rejects unsigned payloads" do
    # The HMAC machinery exists — it's just not invoked by default.
    # Confirm it works when explicitly used, so the fix is "wire it
    # in by default" rather than "build verification from scratch."
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    write_poisoned_checkpoint(ckpt_path, %{
      current_node: "x",
      completed: [],
      poison: %{"anything" => "goes"}
    })

    # Without secret: accepts.
    assert {:ok, _} = Checkpoint.load(ckpt_path)

    # With secret: REJECTS the unsigned payload.
    result = Checkpoint.load(ckpt_path, hmac_secret: "test_secret_32_bytes_xxxxxxxxxxxx")

    assert match?({:error, _}, result),
           "Checkpoint with hmac_secret accepted an unsigned payload — " <>
             "the verification layer itself is broken, not just unwired"
  end

  test "end-to-end: identity_private_key signs on write, same key verifies on resume" do
    # Round-trip property: the engine writes signed checkpoints when
    # identity_private_key is provided, and resume with the same key
    # accepts them.
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    private_key = :crypto.strong_rand_bytes(32)

    # First run — writes a signed checkpoint.
    {:ok, _} =
      Arbor.Orchestrator.run(@capture_dot,
        logs_root: root,
        authorization: false,
        identity_private_key: private_key,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    assert File.exists?(ckpt_path), "engine should have written checkpoint.json"

    # The checkpoint MUST carry an __hmac field (engine signed it).
    {:ok, raw_json} = File.read(ckpt_path)
    {:ok, raw} = Jason.decode(raw_json)
    assert Map.has_key?(raw, "__hmac"), "engine-written checkpoint missing __hmac"

    # Loading without the secret still succeeds (backward compat).
    assert {:ok, _} = Checkpoint.load(ckpt_path)

    # Loading WITH the matching derived secret succeeds.
    secret =
      Module.concat([:Arbor, :Security, :Crypto]).derive_key(
        private_key,
        "arbor-checkpoint-hmac-v1",
        32
      )

    assert {:ok, _} = Checkpoint.load(ckpt_path, hmac_secret: secret)
  end

  test "end-to-end: a DIFFERENT identity's secret rejects a signed checkpoint (tamper / wrong-operator)" do
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    key_a = :crypto.strong_rand_bytes(32)
    key_b = :crypto.strong_rand_bytes(32)

    # Run as identity A — writes signed checkpoint.
    {:ok, _} =
      Arbor.Orchestrator.run(@capture_dot,
        logs_root: root,
        authorization: false,
        identity_private_key: key_a,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    # Identity B's derived secret should fail to verify A's checkpoint.
    secret_b =
      Module.concat([:Arbor, :Security, :Crypto]).derive_key(
        key_b,
        "arbor-checkpoint-hmac-v1",
        32
      )

    assert {:error, _} = Checkpoint.load(ckpt_path, hmac_secret: secret_b)
  end
end
