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

  # ── Path traversal — security regression tests ───────────────────

  describe "path traversal in resource_uri (rejected by URI matcher)" do
    # Security regression: CapabilityStore.authorizes_resource?/2 now
    # rejects any resource URI containing a `..` path segment, before
    # the prefix-match logic runs. URI segments are never legitimately
    # `..` — that vocabulary belongs to filesystem paths, not capability
    # URIs.
    #
    # Pre-fix behavior: the matcher did pure string-prefix matching with
    # no normalization, so a cap for "arbor://fs/read/docs/" silently
    # authorized "arbor://fs/read/docs/../etc/passwd". The intended
    # defense (FileGuard) only fired when callers passed :file_path opt,
    # and 0 of 54 production call sites did.
    #
    # These tests are the committed regression tests required by
    # CLAUDE.md — they fail on HEAD~1 and pass on HEAD.

    test "cap for arbor://fs/read/docs/ does NOT authorize docs/../etc/passwd (security regression)",
         %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/docs/"
        )

      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/docs/../etc/passwd")
    end

    test "even arbor://fs/** wildcard does NOT authorize traversal (security regression)",
         %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/**"
        )

      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/safe/../../etc/passwd")
    end

    test ".. as a bare segment is rejected; legitimate identifiers containing dots are NOT (security regression)",
         %{agent_id: agent} do
      # Confirm the segment check uses path-separator boundaries, not
      # substring match. `foo..bar` and `..bar` are legitimate
      # identifiers; only `..` as a complete segment between `/` is
      # traversal.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/**"
        )

      # Legitimate dotted identifiers — must still authorize.
      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/my..file")

      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/..hidden")

      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/version.1.0")

      # Real traversal — must deny.
      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/foo/../bar")

      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/..")

      assert {:error, _} = Security.authorize(agent, "arbor://fs/read/a/../b/../c")
    end
  end

  # ── Implicit FileGuard normalization (defense-in-depth) ──────────

  describe "implicit FileGuard normalization runs for fs URIs (security regression)" do
    # Security regression: when a caller invokes Security.authorize/4
    # with an arbor://fs/<op>/<path> URI but does NOT pass :file_path
    # opt, the URI matcher's prefix check used to be the only defense.
    # A symlink inside the authorized root that points outside the root
    # was undetectable at the security layer — by design (FileGuard
    # was opt-in via :file_path).
    #
    # As of the FileGuard wiring fix, Security.authorize now runs pure
    # path normalization (SafePath.resolve_within + symlink-escape
    # detection) for every fs URI via
    # FileGuard.normalize_uri_path_for_capability/2. Defense-in-depth
    # against symlink escapes catches a case the URI matcher alone
    # cannot — the URI itself contains no `..` segment, but the
    # filesystem object at the URI path is a symlink to outside the
    # cap's root.

    setup do
      workdir = Path.join(System.tmp_dir!(), "fg_adv_#{:erlang.unique_integer([:positive])}")
      safe_dir = Path.join(workdir, "safe")
      outside_dir = Path.join(workdir, "outside")
      File.mkdir_p!(safe_dir)
      File.mkdir_p!(outside_dir)

      outside_file = Path.join(outside_dir, "secret.txt")
      File.write!(outside_file, "secret contents")

      symlink_path = Path.join(safe_dir, "escape-link")
      File.ln_s!(outside_file, symlink_path)

      on_exit(fn -> File.rm_rf(workdir) end)

      {:ok,
       workdir: workdir,
       safe_dir: safe_dir,
       outside_file: outside_file,
       symlink_path: symlink_path}
    end

    test "symlink inside authorized root pointing OUTSIDE is rejected",
         %{agent_id: agent, safe_dir: safe_dir} do
      # Grant a cap rooted at safe_dir.
      cap_uri = "arbor://fs/read#{safe_dir}/"

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: cap_uri
        )

      # The URI for the symlink itself contains no `..`. The URI
      # matcher accepts. Before the FileGuard wiring, this would
      # return {:ok, :authorized}. After the wiring, it returns
      # {:error, :symlink_escape}.
      symlink_uri = "arbor://fs/read#{safe_dir}/escape-link"

      assert {:error, :symlink_escape} = Security.authorize(agent, symlink_uri)
    end

    test "regular file inside authorized root still authorizes (no false positive)",
         %{agent_id: agent, safe_dir: safe_dir} do
      cap_uri = "arbor://fs/read#{safe_dir}/"

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: cap_uri
        )

      legit_file = Path.join(safe_dir, "legit.txt")
      File.write!(legit_file, "fine")

      legit_uri = "arbor://fs/read#{safe_dir}/legit.txt"

      assert match?({:ok, :authorized, _}, Security.authorize(agent, legit_uri)) or
               match?({:ok, :authorized}, Security.authorize(agent, legit_uri))
    end

    test "intermediate-wildcard cap (arbor://fs/read/foo/**) authorizes paths under it",
         %{agent_id: agent, safe_dir: safe_dir} do
      # Pre-fix smell: FileGuard's extract_root_from_capability/1
      # returns "/foo/**" for these caps and breaks. The new
      # extract_root_for_normalization strips the wildcard suffix.
      cap_uri = "arbor://fs/read#{safe_dir}/**"

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: cap_uri
        )

      legit_file = Path.join(safe_dir, "anywhere.txt")
      File.write!(legit_file, "fine")

      legit_uri = "arbor://fs/read#{safe_dir}/anywhere.txt"

      assert match?({:ok, :authorized, _}, Security.authorize(agent, legit_uri)) or
               match?({:ok, :authorized}, Security.authorize(agent, legit_uri))
    end

    test "non-existent file with intermediate-symlink parent is rejected (write-path defense)",
         %{agent_id: agent, workdir: workdir} do
      # SECURITY REGRESSION TEST (per CLAUDE.md) — fails on HEAD~1
      # (returns :authorized), passes on HEAD (returns :symlink_escape).
      #
      # The write-path attack: agent has `arbor://fs/write/<safe>/`,
      # safe contains a symlink `safe/redirect/` pointing outside.
      # Agent authorizes `arbor://fs/write/<safe>/redirect/newfile.txt`
      # where newfile.txt doesn't exist yet. Without the ancestor-chain
      # check, FileGuard's :not_found branch skips symlink resolution
      # and authorizes — the eventual write lands outside the cap root.
      safe_dir = Path.join(workdir, "writescape_safe")
      outside_dir = Path.join(workdir, "writescape_outside")
      File.mkdir_p!(safe_dir)
      File.mkdir_p!(outside_dir)

      # Create the symlinked sub-directory inside safe.
      redirect_path = Path.join(safe_dir, "redirect")
      File.ln_s!(outside_dir, redirect_path)

      cap_uri = "arbor://fs/write#{safe_dir}/"

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: cap_uri
        )

      # Target doesn't exist (would be created by an eventual write).
      # The URI itself contains no `..`. The intermediate `redirect`
      # directory IS a symlink escaping safe_dir.
      target_uri = "arbor://fs/write#{safe_dir}/redirect/newfile.txt"

      assert {:error, :symlink_escape} = Security.authorize(agent, target_uri)
    end

    test "non-existent file in a real subdirectory of root still authorizes (no false positive)",
         %{agent_id: agent, safe_dir: safe_dir} do
      # Counterpart to the test above — confirms the ancestor walk
      # doesn't false-positive on legitimate non-symlinked
      # intermediate directories.
      sub = Path.join(safe_dir, "real_subdir")
      File.mkdir_p!(sub)

      cap_uri = "arbor://fs/write#{safe_dir}/"

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: cap_uri
        )

      target_uri = "arbor://fs/write#{safe_dir}/real_subdir/will_be_written.txt"

      assert match?({:ok, :authorized, _}, Security.authorize(agent, target_uri)) or
               match?({:ok, :authorized}, Security.authorize(agent, target_uri))
    end

    test "non-fs URI is unaffected by the FileGuard wiring",
         %{agent_id: agent} do
      # Confirm we didn't introduce a regression for shell / api caps.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/exec/git"
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/git/status")
    end
  end
end
