defmodule Arbor.Dashboard.Cores.ExternalAgentsCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.ExternalAgentsCore

  @moduletag :fast

  describe "agent_types/0" do
    test "returns at least one template" do
      types = ExternalAgentsCore.agent_types()
      assert is_list(types)
      assert length(types) > 0
    end

    test "every template has the required fields" do
      for t <- ExternalAgentsCore.agent_types() do
        assert is_binary(t.type)
        assert is_binary(t.label)
        assert is_binary(t.description)
        assert is_list(t.capabilities)
        assert Enum.all?(t.capabilities, &is_map/1)
        assert Enum.all?(t.capabilities, fn c -> is_binary(c.resource) end)
      end
    end

    test "claude_code template is present and has the expected baseline caps" do
      template = ExternalAgentsCore.find_agent_type("claude_code")
      assert template.type == "claude_code"
      assert template.label == "Claude Code"
      resources = Enum.map(template.capabilities, & &1.resource)
      assert "arbor://fs/read/" in resources
      assert "arbor://fs/write/" in resources
      assert "arbor://shell/exec/git" in resources
    end
  end

  describe "find_agent_type/1" do
    test "returns the matching template by string type" do
      template = ExternalAgentsCore.find_agent_type("codex")
      assert template.type == "codex"
    end

    test "falls back to the last (generic) template for unknown types" do
      template = ExternalAgentsCore.find_agent_type("nonexistent_type_xyz")
      assert template.type == "external"
    end

    test "fallback is the same instance regardless of unknown input" do
      a = ExternalAgentsCore.find_agent_type("foo")
      b = ExternalAgentsCore.find_agent_type("bar")
      assert a == b
    end
  end

  describe "new/2 — filtering" do
    test "returns empty rows when owner_agent_id is nil" do
      profiles = [external_profile("owner_a", "agent_1")]
      state = ExternalAgentsCore.new(profiles, nil)
      assert state.owner_agent_id == nil
      assert state.rows == []
    end

    test "returns empty rows when no profiles are external agents" do
      profiles = [
        %{
          agent_id: "agent_1",
          display_name: "Internal Agent",
          metadata: %{},
          created_at: ~U[2026-04-11 12:00:00Z]
        }
      ]

      state = ExternalAgentsCore.new(profiles, "owner_a")
      assert state.rows == []
    end

    test "filters out external agents owned by other principals" do
      profiles = [
        external_profile("owner_b", "agent_1"),
        external_profile("owner_a", "agent_2"),
        external_profile("owner_c", "agent_3")
      ]

      state = ExternalAgentsCore.new(profiles, "owner_a")
      assert length(state.rows) == 1
      assert hd(state.rows).agent_id == "agent_2"
    end

    test "includes only profiles where metadata.external_agent is true" do
      profiles = [
        external_profile("owner_a", "agent_1"),
        # Same owner but not flagged as external
        %{
          agent_id: "agent_2",
          display_name: "internal",
          metadata: %{created_by: "owner_a"},
          created_at: ~U[2026-04-11 12:00:00Z]
        }
      ]

      state = ExternalAgentsCore.new(profiles, "owner_a")
      assert length(state.rows) == 1
      assert hd(state.rows).agent_id == "agent_1"
    end
  end

  describe "new/2 — shaping" do
    test "shapes profiles into row maps with the expected fields" do
      profiles = [external_profile("owner_a", "agent_1", display_name: "Claude on phone")]
      state = ExternalAgentsCore.new(profiles, "owner_a")

      assert [row] = state.rows
      assert row.agent_id == "agent_1"
      assert row.display_name == "Claude on phone"
      assert row.agent_type == "claude_code"
      assert %DateTime{} = row.created_at
    end

    test "falls back to agent_id when display_name is nil" do
      profiles = [external_profile("owner_a", "agent_1", display_name: nil)]
      state = ExternalAgentsCore.new(profiles, "owner_a")

      assert hd(state.rows).display_name == "agent_1"
    end

    test "defaults agent_type to 'external' when not in metadata" do
      profile = %{
        agent_id: "agent_1",
        display_name: "Generic",
        metadata: %{external_agent: true, created_by: "owner_a"},
        created_at: ~U[2026-04-11 12:00:00Z]
      }

      state = ExternalAgentsCore.new([profile], "owner_a")
      assert hd(state.rows).agent_type == "external"
    end
  end

  describe "new/2 — sorting" do
    test "sorts rows by created_at descending (newest first)" do
      profiles = [
        external_profile("owner_a", "agent_old", created_at: ~U[2026-04-01 10:00:00Z]),
        external_profile("owner_a", "agent_new", created_at: ~U[2026-04-11 10:00:00Z]),
        external_profile("owner_a", "agent_mid", created_at: ~U[2026-04-05 10:00:00Z])
      ]

      state = ExternalAgentsCore.new(profiles, "owner_a")
      ids = Enum.map(state.rows, & &1.agent_id)
      assert ids == ["agent_new", "agent_mid", "agent_old"]
    end

    test "handles nil created_at without crashing" do
      profiles = [
        external_profile("owner_a", "agent_a", created_at: nil),
        external_profile("owner_a", "agent_b", created_at: ~U[2026-04-11 10:00:00Z])
      ]

      state = ExternalAgentsCore.new(profiles, "owner_a")
      assert length(state.rows) == 2
    end
  end

  describe "build_registration_opts/3" do
    test "produces a keyword list with the expected keys" do
      opts = ExternalAgentsCore.build_registration_opts("My Agent", "claude_code", nil)

      assert Keyword.has_key?(opts, :capabilities)
      assert Keyword.has_key?(opts, :tenant_context)
      assert Keyword.has_key?(opts, :metadata)
      assert Keyword.get(opts, :return_identity) == true
    end

    test "selects capabilities matching the requested agent type" do
      claude_opts = ExternalAgentsCore.build_registration_opts("My Agent", "claude_code", nil)
      generic_opts = ExternalAgentsCore.build_registration_opts("My Agent", "external", nil)

      claude_resources = Enum.map(claude_opts[:capabilities], & &1.resource)
      generic_resources = Enum.map(generic_opts[:capabilities], & &1.resource)

      assert "arbor://fs/write/" in claude_resources
      refute "arbor://fs/write/" in generic_resources
    end

    test "metadata includes external_agent flag and registered_via marker" do
      opts = ExternalAgentsCore.build_registration_opts("My Agent", "claude_code", nil)
      meta = Keyword.fetch!(opts, :metadata)

      assert meta.external_agent == true
      assert meta.agent_type == "claude_code"
      assert meta.registered_via == "dashboard"
    end

    test "passes through tenant_context unchanged" do
      ctx = %{some: :tenant, context: 42}
      opts = ExternalAgentsCore.build_registration_opts("My Agent", "claude_code", ctx)
      assert Keyword.get(opts, :tenant_context) == ctx
    end
  end

  describe "owns?/2" do
    test "returns true when profile metadata matches owner" do
      profile = external_profile("owner_a", "agent_1")
      assert ExternalAgentsCore.owns?(profile, "owner_a") == true
    end

    test "returns false when owner does not match" do
      profile = external_profile("owner_a", "agent_1")
      assert ExternalAgentsCore.owns?(profile, "owner_b") == false
    end

    test "returns false when profile is not flagged as external" do
      profile = %{
        agent_id: "agent_1",
        display_name: "Internal",
        metadata: %{created_by: "owner_a"},
        created_at: ~U[2026-04-11 12:00:00Z]
      }

      assert ExternalAgentsCore.owns?(profile, "owner_a") == false
    end

    test "returns false when owner is nil" do
      profile = external_profile("owner_a", "agent_1")
      assert ExternalAgentsCore.owns?(profile, nil) == false
    end
  end

  describe "build_just_registered_view/3" do
    test "encodes the private key as base64 and the public key as hex" do
      profile = %{
        agent_id: "agent_xyz",
        display_name: "Test Agent"
      }

      identity = %{
        private_key: <<1, 2, 3, 4>>,
        public_key: <<255, 254, 253, 252>>
      }

      view = ExternalAgentsCore.build_just_registered_view(profile, identity, "claude_code")

      assert view.display_name == "Test Agent"
      assert view.agent_id == "agent_xyz"
      assert view.agent_type == "claude_code"
      assert view.private_key_b64 == Base.encode64(<<1, 2, 3, 4>>)
      assert view.public_key_hex == "fffefdfc"
    end
  end

  describe "build_key_file_contents/2" do
    test "produces a key=value file body for the .arbor.key download" do
      contents = ExternalAgentsCore.build_key_file_contents("agent_xyz", "BASE64KEY==")
      assert String.contains?(contents, "agent_id=agent_xyz")
      assert String.contains?(contents, "private_key_b64=BASE64KEY==")
      assert String.ends_with?(contents, "\n")
    end
  end

  describe "sanitize_filename/1" do
    test "lowercases and replaces non-alphanumeric runs with underscores" do
      assert ExternalAgentsCore.sanitize_filename("Claude On Phone") == "claude_on_phone"
      assert ExternalAgentsCore.sanitize_filename("My-Agent!!") == "my_agent"
      assert ExternalAgentsCore.sanitize_filename("Agent.42") == "agent_42"
    end

    test "trims leading and trailing underscores" do
      assert ExternalAgentsCore.sanitize_filename("!!agent!!") == "agent"
    end

    test "falls back to 'external_agent' for empty or all-symbol input" do
      assert ExternalAgentsCore.sanitize_filename("") == "external_agent"
      assert ExternalAgentsCore.sanitize_filename("!!!") == "external_agent"
    end
  end

  describe "format_time/1" do
    test "formats DateTime as YYYY-MM-DD HH:MM" do
      assert ExternalAgentsCore.format_time(~U[2026-04-11 12:30:00Z]) == "2026-04-11 12:30"
    end

    test "returns em-dash for non-DateTime input" do
      assert ExternalAgentsCore.format_time(nil) == "—"
      assert ExternalAgentsCore.format_time("2026-04-11") == "—"
    end
  end

  describe "format_error/1" do
    test "translates known reasons to user-friendly messages" do
      assert ExternalAgentsCore.format_error(:not_owner) =~ "only modify agents you registered"
      assert ExternalAgentsCore.format_error(:security_unavailable) =~ "Security subsystem"
      assert ExternalAgentsCore.format_error(:return_identity_not_honored) =~ "Internal error"
    end

    test "stringifies unknown error tuples" do
      assert ExternalAgentsCore.format_error({:error, :foo_bar}) =~ ":foo_bar"
    end

    test "stringifies unknown atom reasons" do
      assert ExternalAgentsCore.format_error(:weird_thing) == "Error: weird_thing"
    end
  end

  describe "pipeline composition" do
    test "new |> rows produces a sorted, filtered list end to end" do
      profiles = [
        external_profile("owner_a", "agent_old",
          display_name: "Old",
          created_at: ~U[2026-04-01 10:00:00Z]
        ),
        external_profile("owner_b", "agent_other",
          display_name: "Not mine",
          created_at: ~U[2026-04-11 10:00:00Z]
        ),
        external_profile("owner_a", "agent_new",
          display_name: "New",
          created_at: ~U[2026-04-11 10:00:00Z]
        )
      ]

      rows = ExternalAgentsCore.new(profiles, "owner_a").rows

      assert length(rows) == 2
      assert Enum.map(rows, & &1.display_name) == ["New", "Old"]
    end
  end

  # ---------------------------------------------------------------------------
  # Test fixtures
  # ---------------------------------------------------------------------------

  defp external_profile(owner_id, agent_id, opts \\ []) do
    %{
      agent_id: agent_id,
      display_name: Keyword.get(opts, :display_name, "External"),
      metadata: %{
        external_agent: true,
        created_by: owner_id,
        agent_type: Keyword.get(opts, :agent_type, "claude_code")
      },
      created_at: Keyword.get(opts, :created_at, ~U[2026-04-11 12:00:00Z])
    }
  end
end
