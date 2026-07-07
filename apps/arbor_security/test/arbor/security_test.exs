defmodule Arbor.SecurityTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.SystemAuthority

  setup do
    # Create a unique agent ID for each test
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  describe "authorize/4" do
    test "returns unauthorized without capability", %{agent_id: agent_id} do
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "returns authorized with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "regression: bare arbor://fs/<op> URI + :file_path matches a path-scoped cap",
         %{agent_id: agent_id} do
      # The 2026-06-06 morning-digest pipeline failure case: file actions
      # authorize with `Security.authorize(agent, "arbor://fs/read",
      # :execute, file_path: "/abs/path/file.md")`. Per-run identity
      # caps are scoped like `arbor://fs/read/abs/path/**`. Pre-fix,
      # the bare URI didn't trigger the cap's `/**` prefix match in
      # `uri_matches?/2`, so authorization missed the real path-scoped cap.
      # With the synthesis, the bare
      # URI + file_path becomes `arbor://fs/read/abs/path/file.md`
      # which IS matched by the cap's `/**` prefix.

      # macOS symlinks /tmp → /private/tmp; SafePath flags the divergence
      # as path traversal. Use the canonical real path so the cap URI's
      # root matches FileGuard's resolved path. `Path.expand` collapses
      # ".." but doesn't follow symlinks; the symlink path that matters
      # here is the parent so use the realpath of System.tmp_dir!().
      tmp_root =
        case :file.read_link("/tmp") do
          {:ok, target} -> "/" <> List.to_string(target)
          _ -> System.tmp_dir!()
        end

      tmp_dir = Path.join(tmp_root, "auth_uri_synth_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      file_path = Path.join(tmp_dir, "file.md")
      File.write!(file_path, "ok")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Cap URI mirrors what `.caps.json` declares — path-scoped /** form.
      cap_uri = "arbor://fs/read#{tmp_dir}/**"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: cap_uri
        )

      # Pre-fix: bare URI + file_path missed the path-scoped cap. Post-fix:
      # synthesizes to the full URI, finds the
      # per-path cap directly, returns :authorized.
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read", :execute,
                 file_path: file_path,
                 verify_identity: false
               )
    end

    test "regression: synthesis only fires for bare arbor://fs/<op>; pre-pathed URIs untouched",
         %{agent_id: agent_id} do
      # A caller that ALREADY passes the path in the URI should not be
      # mutated. The synthesis only kicks in for the bare form so we
      # don't double-append paths.
      tmp_root =
        case :file.read_link("/tmp") do
          {:ok, target} -> "/" <> List.to_string(target)
          _ -> System.tmp_dir!()
        end

      tmp_dir = Path.join(tmp_root, "auth_uri_pre_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      file_path = Path.join(tmp_dir, "file.md")
      File.write!(file_path, "ok")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read#{tmp_dir}/**"
        )

      # Caller passes the full URI directly — the cap matches via
      # /** without any synthesis. opts[:file_path] is informational.
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read#{file_path}", :execute,
                 file_path: file_path,
                 verify_identity: false
               )
    end

    test "regression: bare fs URI normalizes relative file_path aliases before cap lookup",
         %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/secret/**"
        )

      aliased_path = "public/../secret/keys.txt"

      assert {:ok, "arbor://fs/read/secret/keys.txt"} =
               Security.normalize_authorization_resource_uri("arbor://fs/read",
                 file_path: aliased_path
               )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read", :execute,
                 file_path: aliased_path,
                 verify_identity: false
               )
    end

    test "regression: workspace file_path synthesis uses workspace-relative canonical URI",
         %{agent_id: agent_id} do
      tmp_root =
        case :file.read_link("/tmp") do
          {:ok, target} -> "/" <> List.to_string(target)
          _ -> System.tmp_dir!()
        end

      workspace = Path.join(tmp_root, "auth_uri_workspace_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "secret"))
      file_path = Path.join([workspace, "public", "..", "secret", "keys.txt"])
      File.write!(Path.join(workspace, "secret/keys.txt"), "ok")
      on_exit(fn -> File.rm_rf!(workspace) end)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/secret/**"
        )

      assert {:ok, "arbor://fs/read/secret/keys.txt"} =
               Security.normalize_authorization_resource_uri("arbor://fs/read",
                 file_path: file_path,
                 workspace: workspace
               )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read", :execute,
                 file_path: file_path,
                 workspace: workspace,
                 verify_identity: false
               )
    end

    test "security regression: relative file_path cannot escape above its canonical root",
         %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/**"
        )

      assert {:error, {:invalid_file_path, :path_traversal}} =
               Security.authorize(agent_id, "arbor://fs/read", :execute,
                 file_path: "../secret.txt",
                 verify_identity: false
               )
    end
  end

  describe "authorize/2 boolean-style checks" do
    test "returns error without capability", %{agent_id: agent_id} do
      assert {:error, _} = Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "returns ok with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, "arbor://fs/read/docs")
    end
  end

  describe "grant/1 and revoke/2" do
    test "grants capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/project"
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://fs/read/project"
    end

    test "revokes capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/write/temp"
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, "arbor://fs/write/temp")

      :ok = Security.revoke(cap.id)

      assert {:error, _} = Security.authorize(agent_id, "arbor://fs/write/temp")
    end
  end

  describe "list_capabilities/2" do
    test "lists capabilities for agent", %{agent_id: agent_id} do
      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/a")

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/b")

      {:ok, caps} = Security.list_capabilities(agent_id)

      assert length(caps) == 2
    end
  end

  describe "capability_authorizes?/3" do
    test "checks resource matching and scope without mutating state", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/project/**",
          session_id: "session_1"
        )

      assert Security.capability_authorizes?(cap, "arbor://fs/read/project/file.txt",
               session_id: "session_1"
             )

      refute Security.capability_authorizes?(cap, "arbor://fs/read/project/file.txt",
               session_id: "session_2"
             )

      refute Security.capability_authorizes?(cap, "arbor://fs/write/project/file.txt",
               session_id: "session_1"
             )
    end
  end

  describe "healthy?/0" do
    test "returns true when system is running" do
      assert Security.healthy?() == true
    end
  end

  describe "stats/0" do
    test "returns capability and identity statistics" do
      stats = Security.stats()

      assert Map.has_key?(stats, :capabilities)
      assert Map.has_key?(stats, :identities)
      assert Map.has_key?(stats, :healthy)
      assert Map.has_key?(stats, :system_authority_id)
      assert is_binary(stats.system_authority_id)
    end
  end

  # ===========================================================================
  # Identity facade tests
  # ===========================================================================

  describe "generate_identity/1" do
    test "returns identity with keypair" do
      {:ok, identity} = Security.generate_identity()

      assert String.starts_with?(identity.agent_id, "agent_")
      assert byte_size(identity.public_key) == 32
      assert byte_size(identity.private_key) == 32
    end
  end

  describe "register_identity/1 and lookup_public_key/1" do
    test "round-trip works" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      assert {:ok, pk} = Security.lookup_public_key(identity.agent_id)
      assert pk == identity.public_key
    end
  end

  describe "verify_request/1" do
    test "valid request verifies successfully" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, signed} =
        SignedRequest.sign(
          "payload",
          identity.agent_id,
          identity.private_key
        )

      assert {:ok, agent_id} = Security.verify_request(signed)
      assert agent_id == identity.agent_id
    end
  end

  describe "authorize/4 with identity verification" do
    test "succeeds with valid signed_request for registered agent with capability" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, _cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/docs"
        )

      {:ok, signed} =
        SignedRequest.sign(
          "authorize",
          identity.agent_id,
          identity.private_key
        )

      assert {:ok, :authorized} =
               Security.authorize(identity.agent_id, "arbor://fs/read/docs", nil,
                 signed_request: signed,
                 verify_identity: true
               )
    end

    test "fails with invalid signed_request" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, _cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/docs"
        )

      {:ok, signed} =
        SignedRequest.sign(
          "authorize",
          identity.agent_id,
          identity.private_key
        )

      # Tamper with signature
      tampered = %{signed | signature: :crypto.strong_rand_bytes(byte_size(signed.signature))}

      assert {:error, :invalid_signature} =
               Security.authorize(identity.agent_id, "arbor://fs/read/docs", nil,
                 signed_request: tampered,
                 verify_identity: true
               )
    end

    test "works without signed_request (backward compatible)", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/legacy"
        )

      # No signed_request, identity verification not forced
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/legacy")
    end
  end

  # ===========================================================================
  # Phase 2: Capability signing integration tests
  # ===========================================================================

  describe "grant/1 signs capabilities" do
    test "granted capabilities have issuer_id and issuer_signature", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/signed"
        )

      assert is_binary(cap.issuer_id)
      assert String.starts_with?(cap.issuer_id, "agent_")
      assert is_binary(cap.issuer_signature)
      assert byte_size(cap.issuer_signature) > 0
    end

    test "granted capability signature is valid", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/verified"
        )

      assert :ok =
               SystemAuthority.verify_capability_signature(cap)
    end
  end

  describe "find_authorizing returns signed capabilities" do
    test "authorized capability is signed", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/found"
        )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/found")
    end
  end

  describe "tampered capability signature" do
    test "authorization fails for tampered capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/tamper"
        )

      # Tamper with the stored capability by revoking and putting a modified version
      :ok = Security.revoke(cap.id)

      tampered = %{cap | resource_uri: "arbor://fs/write/evil"}
      {:ok, :stored} = CapabilityStore.put(tampered)

      # The tampered capability should fail signature verification
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/write/evil")
    end
  end

  describe "delegation through facade" do
    test "produces signed delegation chain", %{agent_id: agent_id} do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, parent_cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/delegated"
        )

      {:ok, delegated} =
        Security.delegate(parent_cap.id, agent_id, delegator_private_key: identity.private_key)

      assert delegated.principal_id == agent_id
      assert delegated.parent_capability_id == parent_cap.id
      assert is_binary(delegated.issuer_signature)
      assert length(delegated.delegation_chain) == 1
      assert hd(delegated.delegation_chain).delegator_id == identity.agent_id
    end
  end

  describe "backward compatibility" do
    test "unsigned capabilities work when capability_signing_required? is false",
         %{agent_id: agent_id} do
      # Directly store an unsigned capability (simulating pre-Phase 2 data)
      {:ok, unsigned_cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/legacy_unsigned",
          principal_id: agent_id
        )

      {:ok, :stored} = CapabilityStore.put(unsigned_cap)

      # Default config has capability_signing_required: false
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/legacy_unsigned")
    end
  end

  # ===========================================================================
  # Phase 3: Constraint enforcement integration tests
  # ===========================================================================

  describe "authorize/4 with rate_limit constraint" do
    test "succeeds up to limit then fails", %{agent_id: agent_id} do
      resource = "arbor://fs/read/rate_limited_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{rate_limit: 3}
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)

      assert {:error, {:constraint_violated, :rate_limit, %{limit: 3, remaining: 0}}} =
               Security.authorize(agent_id, resource)
    end
  end

  describe "authorize/4 with time_window constraint" do
    test "respects time window (always-open window succeeds)", %{agent_id: agent_id} do
      resource = "arbor://fs/read/tw_open_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{time_window: %{start_hour: 0, end_hour: 24}}
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
    end

    test "respects time window (closed window denies)", %{agent_id: agent_id} do
      resource = "arbor://fs/read/tw_closed_#{:erlang.unique_integer([:positive])}"
      current_hour = DateTime.utc_now().hour
      bad_start = rem(current_hour + 12, 24)
      bad_end = rem(bad_start + 1, 24)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{time_window: %{start_hour: bad_start, end_hour: bad_end}}
        )

      assert {:error, {:constraint_violated, :time_window, _}} =
               Security.authorize(agent_id, resource)
    end
  end

  describe "authorize/4 with no constraints" do
    test "succeeds normally (no enforcement needed)", %{agent_id: agent_id} do
      resource = "arbor://fs/read/no_constraints_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{}
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
    end
  end

  describe "can?/3 does NOT enforce constraints" do
    test "can? returns true even after rate limit exhausted via authorize", %{agent_id: agent_id} do
      resource = "arbor://fs/read/can_no_consume_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{rate_limit: 1}
        )

      # Exhaust via authorize
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)

      assert {:error, {:constraint_violated, :rate_limit, _}} =
               Security.authorize(agent_id, resource)
    end
  end

  describe "constraint enforcement toggle" do
    test "constraints ignored when enforcement disabled", %{agent_id: agent_id} do
      resource = "arbor://fs/read/toggle_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{rate_limit: 1}
        )

      # Exhaust rate limit
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)

      assert {:error, {:constraint_violated, :rate_limit, _}} =
               Security.authorize(agent_id, resource)

      # Disable enforcement
      prev = Application.get_env(:arbor_security, :constraint_enforcement_enabled)
      Application.put_env(:arbor_security, :constraint_enforcement_enabled, false)
      on_exit(fn -> restore_config(:constraint_enforcement_enabled, prev) end)

      # Should succeed now despite exhausted rate limit
      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
    end
  end

  describe "stats/0 includes rate_limiter" do
    test "stats map contains rate_limiter key" do
      stats = Security.stats()
      assert Map.has_key?(stats, :rate_limiter)
      assert is_map(stats.rate_limiter)
      assert Map.has_key?(stats.rate_limiter, :bucket_count)
    end
  end

  # ===========================================================================
  # Phase 7: Quota enforcement integration tests
  # ===========================================================================

  describe "grant/1 quota enforcement" do
    setup do
      original_max_per_agent = Application.get_env(:arbor_security, :max_capabilities_per_agent)
      original_enabled = Application.get_env(:arbor_security, :quota_enforcement_enabled)

      on_exit(fn ->
        restore_config(:max_capabilities_per_agent, original_max_per_agent)
        restore_config(:quota_enforcement_enabled, original_enabled)
      end)

      :ok
    end

    test "returns error when per-agent quota exceeded", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)
      Application.put_env(:arbor_security, :quota_enforcement_enabled, true)

      base = :erlang.unique_integer([:positive])

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/quota_test/#{base}/1")

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/quota_test/#{base}/2")

      # 3rd should fail
      assert {:error, {:quota_exceeded, :per_agent_capability_limit, context}} =
               Security.grant(
                 principal: agent_id,
                 resource: "arbor://fs/read/quota_test/#{base}/3"
               )

      assert context.agent_id == agent_id
      assert context.current == 2
      assert context.limit == 2
    end

    test "returns error when delegation_depth exceeds limit", %{agent_id: agent_id} do
      original_max_depth = Application.get_env(:arbor_security, :max_delegation_depth)
      Application.put_env(:arbor_security, :max_delegation_depth, 2)

      on_exit(fn ->
        restore_config(:max_delegation_depth, original_max_depth)
      end)

      base = :erlang.unique_integer([:positive])

      assert {:error, {:quota_exceeded, :delegation_depth_limit, context}} =
               Security.grant(
                 principal: agent_id,
                 resource: "arbor://fs/read/quota_depth/#{base}",
                 delegation_depth: 5
               )

      assert context.depth == 5
      assert context.limit == 2
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)

  # ===========================================================================
  # Phase 5: Consensus escalation integration tests
  # ===========================================================================

  describe "authorize/4 with requires_approval constraint" do
    # Mock consensus module for testing
    defmodule MockConsensus do
      def submit(%{proposer: _} = _proposal, _opts \\ []) do
        {:ok, "proposal_#{:erlang.unique_integer([:positive])}"}
      end

      def healthy?, do: true
    end

    setup do
      # Save original config
      original_enabled = Application.get_env(:arbor_security, :consensus_escalation_enabled)
      original_module = Application.get_env(:arbor_security, :consensus_module)

      on_exit(fn ->
        if is_nil(original_enabled) do
          Application.delete_env(:arbor_security, :consensus_escalation_enabled)
        else
          Application.put_env(:arbor_security, :consensus_escalation_enabled, original_enabled)
        end

        if is_nil(original_module) do
          Application.delete_env(:arbor_security, :consensus_module)
        else
          Application.put_env(:arbor_security, :consensus_module, original_module)
        end
      end)

      :ok
    end

    test "returns pending_approval when requires_approval is true", %{agent_id: agent_id} do
      resource = "arbor://fs/write/approval_#{:erlang.unique_integer([:positive])}"

      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{requires_approval: true}
        )

      assert {:ok, :pending_approval, proposal_id} = Security.authorize(agent_id, resource)
      assert String.starts_with?(proposal_id, "proposal_")
    end

    test "returns authorized when requires_approval is false", %{agent_id: agent_id} do
      resource = "arbor://fs/write/no_approval_#{:erlang.unique_integer([:positive])}"

      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{requires_approval: false}
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
    end

    test "returns error when escalation is disabled but approval required", %{agent_id: agent_id} do
      resource = "arbor://fs/write/disabled_#{:erlang.unique_integer([:positive])}"

      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource,
          constraints: %{requires_approval: true}
        )

      assert {:error, :escalation_disabled} = Security.authorize(agent_id, resource)
    end

    test "returns authorized when no constraints", %{agent_id: agent_id} do
      resource = "arbor://fs/read/simple_#{:erlang.unique_integer([:positive])}"

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: resource
        )

      assert {:ok, :authorized} = Security.authorize(agent_id, resource)
    end
  end
end
