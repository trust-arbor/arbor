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

  test "poisoned checkpoint adopts attacker's session.agent_id at the engine layer" do
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)
    ckpt_path = Path.join(root, "checkpoint.json")

    # The attacker's poison: switch the engine's view of who is
    # running the pipeline. The legitimate caller will be
    # "agent_legitimate"; the checkpoint claims "agent_admin".
    write_poisoned_checkpoint(ckpt_path, %{
      # Resume from start node — engine will run capture next.
      current_node: "start",
      completed: ["start"],
      poison: %{
        "session.agent_id" => "agent_admin",
        # Also poison a context flag a later node might branch on.
        "trust_tier" => "veteran"
      }
    })

    # Capture closure: read agent_id from context (via opts? No — function
    # target receives args from parse_attr_args). We use a different
    # mechanism: the function_handler closure has access to the
    # context-injected agent_id via the engine's authorization layer.
    # Simpler approach: use a side-channel — the function captures
    # whatever it's passed in args and sends to the test process.
    test_pid = self()

    # Use a function_handler that reads from process dict — except
    # the engine doesn't give the function access to context directly.
    # Switch strategy: instead of using function exec, hand-build the
    # check via Engine.run/2 with resume_from and inspect the resulting
    # context for the poisoned values.
    {:ok, run_result} =
      Arbor.Orchestrator.run(@capture_dot,
        logs_root: root,
        resume_from: ckpt_path,
        authorization: false,
        # The function_handler is required for target=function but
        # we mostly care about the resumed context, not what the
        # function does.
        function_handler: fn args ->
          send(test_pid, {:fn_args, args})
          {:ok, %{ran: true}}
        end
      )

    # Pin the escalation: the engine adopted the poisoned agent_id
    # verbatim. There was no HMAC check, no signature, no comparison
    # against the legitimate caller's identity.
    assert run_result.context["session.agent_id"] == "agent_admin",
           "Engine failed to adopt poisoned agent_id — but this test exists " <>
             "to PIN the fail-open. If this assertion changes, checkpoint " <>
             "verification has been added (good!). Update the test accordingly."

    assert run_result.context["trust_tier"] == "veteran"

    # The engine-layer adoption is what's pinned. ExecHandler will
    # later read this as `agent_id`, but the action-layer signed-request
    # check (`check_identity_binding/2` in AuthDecision) is the
    # backstop that prevents the swap from becoming a full escalation
    # IF the resumer's caller passes :signer and identity verification
    # is enabled. The roadmap doc covers both surfaces.
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
end
