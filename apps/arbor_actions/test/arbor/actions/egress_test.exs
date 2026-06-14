defmodule Arbor.Actions.EgressTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Egress

  @moduletag :fast

  # -- Fixtures: minimal action modules declaring classification --------------

  defmodule ReadAction do
    # declares nothing — should default to :read / :none
  end

  defmodule EgressNoResolver do
    def effect_class, do: :network_egress
    # intentionally NO egress_tier/2 — must fail closed to :external_provider
  end

  defmodule WebFetch do
    def effect_class, do: :network_egress

    def egress_tier(params, _ctx) do
      case Arbor.Common.EgressClassifier.locality(params[:url]) do
        :on_host -> :on_host
        :on_premises -> :on_premises
        :public -> :external_peer
      end
    end
  end

  describe "effect_class_for/1" do
    test "undeclared action defaults to :read" do
      assert Egress.effect_class_for(ReadAction) == :read
    end

    test "declared network_egress is read back" do
      assert Egress.effect_class_for(WebFetch) == :network_egress
    end
  end

  describe "egress_tier_for/3" do
    test "non-egress action resolves to :none" do
      assert Egress.egress_tier_for(ReadAction, %{}, %{}) == :none
    end

    test "egress action WITHOUT a resolver fails closed to :external_provider" do
      assert Egress.egress_tier_for(EgressNoResolver, %{}, %{}) == :external_provider
    end

    test "resolver returns :external_peer for a public URL" do
      assert Egress.egress_tier_for(WebFetch, %{url: "https://evil.example.com"}, %{}) ==
               :external_peer
    end

    test "resolver returns :on_host for a loopback URL" do
      assert Egress.egress_tier_for(WebFetch, %{url: "http://127.0.0.1:8080"}, %{}) == :on_host
    end

    test "resolver returns :on_premises for a homelab URL" do
      assert Egress.egress_tier_for(WebFetch, %{url: "http://10.42.42.6:11434"}, %{}) ==
               :on_premises
    end
  end

  describe "gate_decision/2" do
    test "external_provider asks" do
      assert Egress.gate_decision(:external_provider) == :ask
    end

    test "external_peer is advisory in 1.0 (enforcement deferred)" do
      assert Egress.gate_decision(:external_peer) == :advise
    end

    test "on_host is allowed" do
      assert Egress.gate_decision(:on_host) == :allow
    end

    test "none is allowed" do
      assert Egress.gate_decision(:none) == :allow
    end

    test "on_premises is allowed by default (homelab/data-sovereignty)" do
      assert Egress.gate_decision(:on_premises) == :allow
    end

    test "on_premises is gated when the operator opts in via opts" do
      assert Egress.gate_decision(:on_premises, gate_on_premises: true) == :ask
    end

    test "on_premises opt-in via application config" do
      Application.put_env(:arbor_security, :gate_on_premises_egress, true)
      on_exit(fn -> Application.delete_env(:arbor_security, :gate_on_premises_egress) end)
      assert Egress.gate_decision(:on_premises) == :ask
    end
  end
end
