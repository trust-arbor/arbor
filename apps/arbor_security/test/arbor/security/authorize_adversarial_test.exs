defmodule Arbor.Security.AuthorizeAdversarialTest do
  @moduledoc """
  Adversarial inputs to `Arbor.Security.authorize/4` and the URI matcher
  underneath it.

  Capability-based auth is the trust boundary for every action in Arbor.
  If the matcher fails open — granting access to a resource the operator
  didn't actually intend — agents can escalate beyond their granted scope.
  Conversely, if a wildcard / subpath rule is over-broad, a narrow grant
  silently authorizes far more than the operator thought.

  Tests in three groups:

    1. **Baseline denials** — no cap / wrong principal / revoked / expired.
       These must deny. If they pass, the system is fundamentally broken.
    2. **URI matcher boundaries** — subpath rules don't bleed across
       siblings (`git` doesn't grant `gitleaks`), prefix rules don't
       grant arbitrary deeper paths without the explicit wildcard,
       and bogus schemes don't match `arbor://`.
    3. **Defense-in-depth** — path traversal at the resource_uri layer.
       The URI matcher itself doesn't normalize `..`, so `arbor://fs/read/docs/`
       can structurally "match" `arbor://fs/read/docs/../etc/passwd`. The
       FileGuard layer is what's supposed to catch that. Pin both
       behaviors so a regression in either is visible.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security

  setup do
    agent_id = "agent_adv_#{:erlang.unique_integer([:positive])}"
    other_agent = "agent_other_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id, other_agent: other_agent}
  end

  # ── Baseline denials ──────────────────────────────────────────────

  describe "baseline denials" do
    test "no capability → unauthorized", %{agent_id: agent} do
      assert {:error, :unauthorized} =
               Security.authorize(agent, "arbor://fs/read/anywhere")
    end

    test "capability for OTHER principal does NOT help this agent",
         %{agent_id: agent, other_agent: other} do
      {:ok, _cap} =
        Security.grant(
          principal: other,
          resource: "arbor://fs/read/shared"
        )

      assert {:error, :unauthorized} =
               Security.authorize(agent, "arbor://fs/read/shared")
    end

    test "revoked capability is denied", %{agent_id: agent} do
      {:ok, cap} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/write/temp_adv"
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/write/temp_adv")

      :ok = Security.revoke(cap.id)

      assert {:error, _} = Security.authorize(agent, "arbor://fs/write/temp_adv")
    end

    test "Security.grant REJECTS backdated capabilities (cannot create pre-expired caps)",
         %{agent_id: agent} do
      # The system refuses to issue capabilities whose expires_at is
      # already in the past — `{:error, {:expires_before_granted, ...}}`.
      # This is the actual security property: a caller can't manufacture
      # a pre-expired capability to satisfy an audit ("yes we granted
      # them access — well, technically just for the past hour").
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      assert {:error, {:expires_before_granted, _expires, _granted}} =
               Security.grant(
                 principal: agent,
                 resource: "arbor://fs/read/expired_test",
                 expires_at: past
               )
    end
  end

  # ── URI matcher boundaries ────────────────────────────────────────

  describe "subpath grants don't bleed across siblings" do
    test "cap for arbor://shell/exec/git grants subpaths but NOT git-suffixed siblings",
         %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/exec/git"
        )

      # SHOULD authorize: exact match and subpath (with explicit `/`)
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/git")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/git/status")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/git/log")

      # MUST NOT authorize: sibling-with-prefix names. If the matcher
      # was treating `git` as a string prefix without requiring `/`,
      # these would silently get green-lit.
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/gitleaks")
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/github")
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/git-leaks")
    end

    test "cap without trailing slash does NOT grant unrelated suffix", %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/doc"
        )

      # Exact granted.
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/read/doc")
      # Subpath via explicit slash granted.
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/read/doc/readme.md")
      # Sibling with shared prefix denied.
      assert {:error, _} = Security.authorize(agent, "arbor://fs/read/docs")
      assert {:error, _} = Security.authorize(agent, "arbor://fs/read/document")
    end
  end

  describe "wildcard patterns" do
    test "/** suffix matches any deeper resource", %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/**"
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/read/anything")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/read/deeply/nested/path")
      # But cross-namespace MUST NOT match.
      assert {:error, _} = Security.authorize(agent, "arbor://fs/write/anything")
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/git")
    end

    test "/** does NOT match a resource whose scheme is wrong", %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/**"
        )

      # `evil://` scheme should never match an arbor:// capability,
      # even if the rest of the URI matches the prefix.
      assert {:error, _} = Security.authorize(agent, "evil://fs/read/secrets")
      # Missing scheme prefix entirely.
      assert {:error, _} = Security.authorize(agent, "fs/read/secrets")
    end
  end

  describe "bogus / empty URIs" do
    test "empty resource URI in authorize call denies", %{agent_id: agent} do
      # Doesn't matter what's granted — an empty resource URI should
      # never authorize anything.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/anywhere"
        )

      assert {:error, _} = Security.authorize(agent, "")
    end

    test "garbage resource URI denies", %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/anywhere"
        )

      assert {:error, _} = Security.authorize(agent, "not a uri at all")

      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/<script>alert(1)</script>")
    end
  end

  # ── Path traversal — KNOWN GAP ───────────────────────────────────

  describe "path traversal in resource_uri (CURRENTLY FAIL-OPEN)" do
    @tag :security_known_gap
    test "cap for arbor://fs/read/docs/ silently authorizes docs/../etc/passwd",
         %{agent_id: agent} do
      # KNOWN SECURITY GAP — pinned current behavior so the fix is
      # visible as a flipped assertion when it lands.
      # See `.arbor/roadmap/0-inbox/security-uri-matcher-path-traversal-fail-open.md`.
      #
      # The URI matcher (CapabilityStore.authorizes_resource?/2) does
      # pure string prefix matching with no `..` normalization. So
      # `arbor://fs/read/docs/` MATCHES `arbor://fs/read/docs/../etc/passwd`
      # at the cap layer.
      #
      # The intended defense — FileGuard — only runs when the caller
      # passes `:file_path` in the opts. Survey of the codebase: 54
      # call sites of `Security.authorize/4`, ZERO pass `:file_path`.
      # So FileGuard never runs through this path in production code.
      #
      # Result: any caller that authorizes against a resource URI
      # containing `..` segments gets a green light if the cap prefix
      # matches. This is a fail-open.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/docs/"
        )

      # Pin current behavior: silent grant. When fixed, this assertion
      # flips to {:error, _}.
      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/docs/../etc/passwd")
    end

    @tag :security_known_gap
    test "even the wildcard cap arbor://fs/** fails-open on traversal",
         %{agent_id: agent} do
      # The simplest fail-open: an agent with broad fs:** access can
      # use a `..`-containing URI to authorize against arbitrary paths.
      # FileGuard isn't invoked, so there's nothing in the chain that
      # normalizes the path before granting.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/**"
        )

      # Traversal sneaks through — current behavior.
      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/safe/../../etc/passwd")

      # When fixed, the URI matcher should reject the `..` segment
      # regardless of whether :file_path is in opts.
    end
  end
end
