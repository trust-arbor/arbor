defmodule Arbor.Security.DisclosureEgressRegressionTest do
  @moduledoc """
  Public-facade security regressions for VP-05D2A0 (prerequisite for
  VOICE-17, which remains planned): `Arbor.Security.authorize_egress/3` with
  an interactive-disclosure capability candidate, plus ordinary-candidate
  compatibility and durable-audit-event coverage.

  These fail on a build without the hardened `authorize_egress/3` (any
  disclosure id, however malformed, would be silently ignored and untrusted
  external-provider egress would simply hard-block with no override path at
  all — or, pre-VP-05D2A0, the raw `list_for_principal/2` shortcut would let
  an invalid ordinary candidate wrongly refine `:ask`) and pass with it.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Capability, Identity}

  alias Arbor.Security.{
    Capability.Signer,
    CapabilityStore,
    Events,
    Identity.Registry,
    SystemAuthority
  }

  @resource "arbor://ai/generate"

  setup do
    prev_enforce = Application.get_env(:arbor_security, :egress_gate_enforcing)
    on_exit(fn -> restore(:egress_gate_enforcing, prev_enforce) end)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    unique = :erlang.unique_integer([:positive])

    %{
      agent_id: Arbor.Identifiers.generate_agent_id(),
      session_id: "session_#{unique}",
      task_id: "task_#{unique}",
      principal_scope: "human_#{unique}"
    }
  end

  describe "a valid exact disclosure capability" do
    @tag spec: "VP-05D2A0"
    test "admits :untrusted only on its exact route", ctx do
      cap = issue!(ctx)

      assert Arbor.Security.authorize_egress(
               ctx.agent_id,
               :external_provider,
               full_opts(ctx, cap.id, :untrusted)
             ) == :allow
    end

    @tag spec: "VP-05D2A0"
    test "still blocks :hostile on the same cap/route", ctx do
      cap = issue!(ctx)

      assert {:error, {:egress_blocked, :external_provider, :hostile}} =
               Arbor.Security.authorize_egress(
                 ctx.agent_id,
                 :external_provider,
                 full_opts(ctx, cap.id, :hostile)
               )
    end

    @tag spec: "VP-05D2A0"
    test "does not admit a different destination/provider/runtime/model", ctx do
      cap = issue!(ctx)

      for override <- [
            [egress_destination: "evil.example.com"],
            [egress_provider: "openai"],
            [egress_runtime: "acp"]
          ] do
        opts = full_opts(ctx, cap.id, :untrusted, override)

        assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
                 Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
      end
    end

    @tag spec: "VP-05D2A0"
    test "security regression: an explicitly selected model must match exactly", ctx do
      cap = issue!(ctx, model: "claude-sonnet-5")

      matching_opts =
        full_opts(ctx, cap.id, :untrusted, egress_model: "claude-sonnet-5")

      assert Arbor.Security.authorize_egress(
               ctx.agent_id,
               :external_provider,
               matching_opts
             ) == :allow

      for opts <- [
            full_opts(ctx, cap.id, :untrusted),
            full_opts(ctx, cap.id, :untrusted, egress_model: "claude-opus-5")
          ] do
        assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
                 Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
      end
    end
  end

  describe "public authorize_egress/3 refuses every malformed disclosure candidate" do
    setup ctx do
      %{base: base_disclosure_capability(ctx)}
    end

    @tag spec: "VP-05D2A0"
    test "forged signature is refused", %{base: base} = ctx do
      forged = %{base | issuer_signature: :crypto.strong_rand_bytes(64)}
      {:ok, :stored} = CapabilityStore.put(forged)
      assert_refused(ctx, forged.id)
    end

    @tag spec: "VP-05D2A0"
    test "unsigned is refused", %{base: base} = ctx do
      {:ok, :stored} = CapabilityStore.put(base)
      assert_refused(ctx, base.id)
    end

    @tag spec: "VP-05D2A0"
    test "expired is refused", %{base: base} = ctx do
      expired = %{base | expires_at: DateTime.add(DateTime.utc_now(), -10, :second)}
      {:ok, signed} = SystemAuthority.sign_capability(expired)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: future-dated grant is refused", %{base: base} = ctx do
      granted_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      future = %{
        base
        | granted_at: granted_at,
          expires_at: DateTime.add(granted_at, 300, :second)
      }

      {:ok, signed} = SystemAuthority.sign_capability(future)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: non-positive validity window is refused", %{base: base} = ctx do
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
      invalid = %{base | granted_at: DateTime.add(expires_at, 1, :second), expires_at: expires_at}
      {:ok, signed} = SystemAuthority.sign_capability(invalid)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: malformed signature field is refused", %{base: base} = ctx do
      malformed = %{
        base
        | issuer_id: SystemAuthority.agent_id(),
          issuer_signature: {:not, :a_binary}
      }

      {:ok, :stored} = CapabilityStore.put(malformed)
      assert_refused(ctx, malformed.id)
      assert is_binary(SystemAuthority.agent_id())
    end

    @tag spec: "VP-05D2A0"
    test "security regression: a different registered issuer cannot mint disclosure authority",
         %{base: base} = ctx do
      {:ok, other_identity} = Identity.generate()
      :ok = Registry.register(Identity.public_only(other_identity))

      signed =
        base
        |> Map.put(:issuer_id, other_identity.agent_id)
        |> Signer.sign(other_identity.private_key)

      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: non-exact disclosure resource URI is refused",
         %{base: base} = ctx do
      malformed = %{base | resource_uri: base.resource_uri <> "/extra"}
      {:ok, signed} = SystemAuthority.sign_capability(malformed)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "wrong principal is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts = full_opts(ctx, signed.id, :untrusted)

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(
                 Arbor.Identifiers.generate_agent_id(),
                 :external_provider,
                 opts
               )
    end

    @tag spec: "VP-05D2A0"
    test "wrong session is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts =
        Keyword.put(full_opts(ctx, signed.id, :untrusted), :session_id, "session_someone_else")

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "wrong turn/task is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts = Keyword.put(full_opts(ctx, signed.id, :untrusted), :task_id, "task_someone_else")

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "wrong human is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts =
        Keyword.put(full_opts(ctx, signed.id, :untrusted), :principal_scope, "human_someone_else")

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "delegated is refused", %{base: base} = ctx do
      delegated = %{
        base
        | parent_capability_id: "cap_parent_#{:erlang.unique_integer([:positive])}"
      }

      {:ok, signed} = SystemAuthority.sign_capability(delegated)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "revoked is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)
      :ok = CapabilityStore.revoke(signed.id)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "malformed (dual-purpose constraints) is refused", %{base: base} = ctx do
      dual = %{
        base
        | constraints: Map.put(base.constraints, :egress, %{max_tier: :external_provider})
      }

      {:ok, signed} = SystemAuthority.sign_capability(dual)
      {:ok, :stored} = CapabilityStore.put(signed)
      assert_refused(ctx, signed.id)
    end

    @tag spec: "VP-05D2A0"
    test "wrong route is refused", %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts =
        Keyword.put(
          full_opts(ctx, signed.id, :untrusted),
          :egress_destination,
          "evil.example.com"
        )

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "a caller-supplied capability struct (never accepted) is ignored — only an id opt works",
         %{base: base} = ctx do
      {:ok, signed} = SystemAuthority.sign_capability(base)
      {:ok, :stored} = CapabilityStore.put(signed)

      opts = Keyword.put(full_opts(ctx, signed.id, :untrusted), :disclosure_capability_id, signed)

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "no disclosure_capability_id opt at all is refused (no broad covering-cap search)",
         ctx do
      opts = Keyword.delete(full_opts(ctx, "irrelevant", :untrusted), :disclosure_capability_id)

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: malformed authorize_egress opts fail closed without raising",
         ctx do
      assert {:error, {:egress_blocked, :external_provider, :invalid_options}} =
               Arbor.Security.authorize_egress(
                 ctx.agent_id,
                 :external_provider,
                 %{"egress_taint" => "untrusted"}
               )
    end
  end

  describe "ordinary-candidate compatibility" do
    @tag spec: "VP-05D2A0"
    test "an expired ordinary constraints.egress cap no longer refines :ask", %{
      agent_id: agent_id
    } do
      {:ok, cap} =
        Capability.new(
          resource_uri: @resource,
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1),
          constraints: %{egress: %{max_tier: :external_provider}}
        )

      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -3600)}
      {:ok, signed} = SystemAuthority.sign_capability(expired)
      {:ok, :stored} = CapabilityStore.put(signed)

      assert Arbor.Security.authorize_egress(agent_id, :external_provider) ==
               {:requires_approval, :egress}
    end

    @tag spec: "VP-05D2A0"
    test "a valid current signed scoped ordinary cap still refines :ask -> :allow", %{
      agent_id: agent_id
    } do
      {:ok, cap} =
        Capability.new(
          resource_uri: @resource,
          principal_id: agent_id,
          constraints: %{egress: %{max_tier: :external_provider}}
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      assert Arbor.Security.authorize_egress(agent_id, :external_provider) == :allow
    end
  end

  describe "bounded egress telemetry" do
    @tag spec: "VP-05D2A0"
    test "security regression: malformed disclosure ids are never copied into telemetry", ctx do
      parent = self()
      handler_id = "disclosure-egress-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:arbor, :security, :egress_observed],
          fn _event, _measurements, metadata, _config ->
            send(parent, {:egress_observed, metadata})
          end,
          %{}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      oversized_id = "cap_" <> String.duplicate("a", 10_000)

      assert {:requires_approval, :egress} =
               Arbor.Security.authorize_egress(
                 ctx.agent_id,
                 :external_provider,
                 egress_taint: :trusted,
                 disclosure_capability_id: oversized_id
               )

      assert_receive {:egress_observed, metadata}
      assert metadata.data.disclosure_requested
      assert metadata.data.disclosure_capability_id == nil
      assert metadata.signal_data.disclosure_capability_id == nil
    end
  end

  describe "durable audit event" do
    setup do
      name = Arbor.Historian.EventLog.ETS
      backend = Arbor.Persistence.EventLog.ETS

      case apply(backend, :start_link, [[name: name]]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      on_exit(fn ->
        try do
          if Process.whereis(name), do: GenServer.stop(name)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    @tag spec: "VP-05D2A0"
    test "issue_disclosure_capability/1 records a durable capability_granted event, not just the optional cluster signal",
         ctx do
      cap = issue!(ctx)

      {:ok, events} = Events.get_by_type(:capability_granted)

      assert Enum.any?(events, fn event ->
               event_data_value(event.data, "capability_id") == cap.id
             end)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp issue!(ctx, overrides \\ []) do
    {:ok, cap} =
      [
        principal_id: ctx.agent_id,
        session_id: ctx.session_id,
        task_id: ctx.task_id,
        principal_scope: ctx.principal_scope,
        destination: "api.anthropic.com",
        provider: "anthropic",
        runtime: "arbor"
      ]
      |> Keyword.merge(overrides)
      |> Arbor.Security.issue_disclosure_capability()

    cap
  end

  defp base_disclosure_capability(ctx) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    %Capability{
      id: capability_id(),
      resource_uri: "arbor://egress/disclose/" <> token,
      principal_id: ctx.agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      delegation_depth: 0,
      max_uses: nil,
      session_id: ctx.session_id,
      task_id: ctx.task_id,
      principal_scope: ctx.principal_scope,
      constraints: %{
        disclosure: %{
          kind: :interactive_human,
          destination: "api.anthropic.com",
          provider: "anthropic",
          runtime: "arbor"
        }
      },
      delegation_chain: [],
      metadata: %{}
    }
  end

  defp full_opts(ctx, cap_id, taint, route_overrides \\ []) do
    [
      session_id: ctx.session_id,
      task_id: ctx.task_id,
      principal_scope: ctx.principal_scope,
      egress_taint: taint,
      disclosure_capability_id: cap_id,
      egress_destination: "api.anthropic.com",
      egress_provider: "anthropic",
      egress_runtime: "arbor"
    ]
    |> Keyword.merge(route_overrides)
  end

  defp assert_refused(ctx, cap_id) do
    opts = full_opts(ctx, cap_id, :untrusted)

    assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
             Arbor.Security.authorize_egress(ctx.agent_id, :external_provider, opts)
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, val), do: Application.put_env(:arbor_security, key, val)

  defp event_data_value(data, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp capability_id do
    "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
