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

    def egress_destination(params, _ctx), do: URI.parse(params[:url] || "").host
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

  describe "egress_destination_for/3" do
    test "returns nil when the action declares no destination" do
      assert Egress.egress_destination_for(EgressNoResolver, %{}, %{}) == nil
      assert Egress.egress_destination_for(ReadAction, %{}, %{}) == nil
    end

    test "returns the resolved host when the action declares egress_destination/2" do
      assert Egress.egress_destination_for(WebFetch, %{url: "https://api.example.com/v1"}, %{}) ==
               "api.example.com"
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

  # Guards the REAL action declarations (not fixtures) — the egress surface the
  # gate actually classifies. A regression here means an egressing action lost
  # its classification and would slip the gate.
  describe "real egressing action declarations" do
    test "AI actions are network egress; tier follows the resolved provider" do
      for mod <- [Arbor.Actions.AI.GenerateText, Arbor.Actions.AI.AnalyzeCode] do
        assert Egress.effect_class_for(mod) == :network_egress
        assert Egress.egress_tier_for(mod, %{provider: "anthropic"}, %{}) == :external_provider
        assert Egress.egress_tier_for(mod, %{provider: "lmstudio"}, %{}) == :on_host
        # nil provider (routing decides later) fails closed to external
        assert Egress.egress_tier_for(mod, %{}, %{}) == :external_provider
      end
    end

    test "Web fetches are network egress; tier follows the URL host" do
      for mod <- [Arbor.Actions.Web.Browse, Arbor.Actions.Web.Snapshot] do
        assert Egress.effect_class_for(mod) == :network_egress
        assert Egress.egress_tier_for(mod, %{url: "https://example.com"}, %{}) == :external_peer
        assert Egress.egress_tier_for(mod, %{url: "http://127.0.0.1:8080"}, %{}) == :on_host
        assert Egress.egress_tier_for(mod, %{url: "http://10.42.42.6"}, %{}) == :on_premises
      end
    end

    test "Web searches hit fixed external APIs (:external_provider via fail-closed default)" do
      for mod <- [
            Arbor.Actions.Web.Search,
            Arbor.Actions.Web.ExaSearch,
            Arbor.Actions.Web.TinyfishSearch
          ] do
        assert Egress.effect_class_for(mod) == :network_egress
        assert Egress.egress_tier_for(mod, %{query: "x"}, %{}) == :external_provider
      end
    end

    test "Comms.SendMessage is egress to an external provider" do
      assert Egress.effect_class_for(Arbor.Actions.Comms.SendMessage) == :network_egress

      assert Egress.egress_tier_for(Arbor.Actions.Comms.SendMessage, %{channel: :email}, %{}) ==
               :external_provider
    end

    test "Comms.PollMessages is ingress — NOT classified as egress" do
      assert Egress.effect_class_for(Arbor.Actions.Comms.PollMessages) == :read
      assert Egress.egress_tier_for(Arbor.Actions.Comms.PollMessages, %{}, %{}) == :none
    end

    test "ACP session actions are egress to an external peer (advisory-only deferral)" do
      for mod <- [Arbor.Actions.Acp.StartSession, Arbor.Actions.Acp.SendMessage] do
        assert Egress.effect_class_for(mod) == :network_egress
        assert Egress.egress_tier_for(mod, %{}, %{}) == :external_peer
      end
    end

    test "internal Channel actions do NOT egress off-host" do
      for mod <- [Arbor.Actions.Channel.List, Arbor.Actions.Channel.Read] do
        assert Egress.effect_class_for(mod) == :read
        assert Egress.egress_tier_for(mod, %{}, %{}) == :none
      end
    end

    test "Web actions expose the fetched host as egress_destination (destination-scoped caps)" do
      for mod <- [Arbor.Actions.Web.Browse, Arbor.Actions.Web.Snapshot] do
        assert Egress.egress_destination_for(mod, %{url: "https://api.example.com/v1"}, %{}) ==
                 "api.example.com"

        assert Egress.egress_destination_for(mod, %{url: "http://10.42.42.6:11434"}, %{}) ==
                 "10.42.42.6"
      end
    end

    test "AI actions expose the provider as egress_destination (nil when routing)" do
      for mod <- [Arbor.Actions.AI.GenerateText, Arbor.Actions.AI.AnalyzeCode] do
        assert Egress.egress_destination_for(mod, %{provider: "anthropic"}, %{}) == "anthropic"
        assert Egress.egress_destination_for(mod, %{}, %{}) == nil
      end
    end
  end
end
