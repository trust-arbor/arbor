defmodule Arbor.Trust.ApprovalContextTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.ApprovalContext
  alias Arbor.Trust.CapabilityProfileRegistry

  defp explanation(overrides \\ %{}) do
    Map.merge(
      %{
        resource_uri: "arbor://fs/write/report.md",
        user_mode: :ask,
        user_match: {"arbor://fs/write", :ask},
        baseline: :ask,
        security_ceiling: :ask,
        ceiling_match: {"arbor://fs/write", :ask},
        model_class: nil,
        model_ceiling: :auto,
        taint_mode: :auto,
        operation_taint: :trusted,
        effect_class: :local_write,
        effective_mode: :ask
      },
      overrides
    )
  end

  describe "build/3 with injected lookups" do
    test "flattens the explanation and profile into a JSON-clean map" do
      explain = fn "agent_1", "arbor://fs/write/report.md", _opts -> explanation() end
      profile = fn uri -> CapabilityProfileRegistry.profile_for(uri) end

      ctx =
        ApprovalContext.build("agent_1", "arbor://fs/write/report.md",
          explain_fun: explain,
          profile_fun: profile
        )

      assert ctx.effective_mode == :ask
      assert ctx.user_mode == :ask
      assert ctx.baseline == :ask
      assert ctx.matched_rule == %{prefix: "arbor://fs/write", mode: :ask}
      assert ctx.ceiling_match == %{prefix: "arbor://fs/write", mode: :ask}

      # The real registry profile for fs/write: high blast radius, reversible.
      assert ctx.profile.uri_prefix == "arbor://fs/write"
      assert ctx.profile.reversibility == :reversible
      assert ctx.profile.blast_radius == :high
      assert ctx.profile.effect_class == :local_write
      assert is_integer(ctx.profile.graduation_threshold)

      # No tuples anywhere: the map crosses the engine's JSON boundary.
      refute contains_tuple?(ctx)
    end

    test "irreversible profiles report graduation_threshold :never" do
      ctx =
        ApprovalContext.build("agent_1", "arbor://shell/exec/rm",
          explain_fun: fn _, _, _ -> nil end
        )

      assert ctx.profile.reversibility == :irreversible
      assert ctx.profile.blast_radius == :critical
      assert ctx.profile.graduation_threshold == :never
      refute Map.has_key?(ctx, :effective_mode)
    end

    test "omits matched_rule when no user rule matched" do
      explain = fn _, _, _ -> explanation(%{user_match: nil, ceiling_match: nil}) end

      ctx =
        ApprovalContext.build("agent_1", "arbor://fs/write/report.md",
          explain_fun: explain,
          profile_fun: fn _ -> nil end
        )

      refute Map.has_key?(ctx, :matched_rule)
      refute Map.has_key?(ctx, :ceiling_match)
      refute Map.has_key?(ctx, :profile)
      assert ctx.effective_mode == :ask
    end

    test "records a policy error instead of dropping the explanation" do
      explain = fn _, _, _ ->
        %{resource_uri: "arbor://x", error: :policy_host_unavailable, effective_mode: :block}
      end

      ctx =
        ApprovalContext.build("agent_1", "arbor://x",
          explain_fun: explain,
          profile_fun: fn _ -> nil end
        )

      assert ctx.effective_mode == :block
      assert ctx.explain_error == :policy_host_unavailable
    end

    test "fails soft when a lookup raises or exits" do
      ctx =
        ApprovalContext.build("agent_1", "arbor://fs/write/report.md",
          explain_fun: fn _, _, _ -> raise "policy down" end,
          profile_fun: fn _ -> exit(:registry_down) end
        )

      assert ctx == %{}
    end

    test "only forwards admissible explain options" do
      parent = self()

      explain = fn _, _, opts ->
        send(parent, {:explain_opts, opts})
        explanation()
      end

      ApprovalContext.build("agent_1", "arbor://fs/write/report.md",
        explain_fun: explain,
        profile_fun: fn _ -> nil end,
        model_class: :frontier_cloud,
        file_path: "/tmp/x",
        approval_context: %{target: "x"}
      )

      assert_received {:explain_opts, opts}
      assert Keyword.get(opts, :model_class) == :frontier_cloud
      refute Keyword.has_key?(opts, :file_path)
      refute Keyword.has_key?(opts, :approval_context)
    end
  end

  describe "profile_summary/1" do
    test "summarises a profile and derives the graduation threshold" do
      profile =
        CapabilityProfile.new!(
          uri_prefix: "arbor://test/irreversible",
          owner: :arbor_trust,
          blast_radius: :high,
          reversibility: :irreversible,
          effect_class: :local_write,
          data_class: :confidential,
          arg_dependent: true,
          default_approval: :require_human,
          delegable: false,
          cost_class: :cheap,
          graduation_eligible: true
        )

      summary = ApprovalContext.profile_summary(profile)
      assert summary.reversibility == :irreversible
      assert summary.graduation_threshold == :never
    end

    test "returns nil for non-profiles" do
      assert ApprovalContext.profile_summary(nil) == nil
      assert ApprovalContext.profile_summary(%{reversibility: :reversible}) == nil
    end
  end

  describe "build/3 against the real policy host" do
    setup do
      assert {:ok, _} = Application.ensure_all_started(:arbor_trust)
      :ok
    end

    test "an unknown agent still gets an explanation and the ceiling" do
      ctx =
        ApprovalContext.build(
          "agent_unknown_#{System.unique_integer([:positive])}",
          "arbor://shell/exec/git"
        )

      assert ctx.effective_mode == :ask
      assert ctx.security_ceiling == :ask
      assert ctx.profile.reversibility == :irreversible
      refute contains_tuple?(ctx)
    end
  end

  defp contains_tuple?(value) when is_tuple(value), do: true

  defp contains_tuple?(value) when is_map(value) and not is_struct(value),
    do: Enum.any?(value, fn {_k, v} -> contains_tuple?(v) end)

  defp contains_tuple?(value) when is_list(value), do: Enum.any?(value, &contains_tuple?/1)
  defp contains_tuple?(_), do: false
end
