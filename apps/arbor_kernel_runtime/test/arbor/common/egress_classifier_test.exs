defmodule Arbor.Common.EgressClassifierTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.EgressClassifier

  @moduletag :fast

  doctest EgressClassifier

  describe "locality/1 — on-host (loopback)" do
    test "localhost" do
      assert EgressClassifier.locality("localhost") == :on_host
    end

    test "IPv4 loopback literal" do
      assert EgressClassifier.locality("127.0.0.1") == :on_host
    end

    test "IPv4 loopback anywhere in 127/8" do
      assert EgressClassifier.locality("127.5.5.5") == :on_host
    end

    test "0.0.0.0 (this host)" do
      assert EgressClassifier.locality("0.0.0.0") == :on_host
    end

    test "IPv6 loopback ::1" do
      assert EgressClassifier.locality("::1") == :on_host
    end

    test "loopback inside a URL with port (LM Studio)" do
      assert EgressClassifier.locality("http://127.0.0.1:1234/v1/chat") == :on_host
    end

    test "localhost inside a URL" do
      assert EgressClassifier.locality("http://localhost:11434") == :on_host
    end

    test "bracketed IPv6 loopback in a URL" do
      assert EgressClassifier.locality("http://[::1]:8080/x") == :on_host
    end

    test ".localhost suffix" do
      assert EgressClassifier.locality("foo.localhost") == :on_host
    end
  end

  describe "locality/1 — on-premises (private LAN, the homelab)" do
    test "10.0.0.0/8 (the 10.42.42.x P40 box)" do
      assert EgressClassifier.locality("10.42.42.6") == :on_premises
    end

    test "192.168.0.0/16" do
      assert EgressClassifier.locality("192.168.1.50") == :on_premises
    end

    test "172.16.0.0/12 lower bound" do
      assert EgressClassifier.locality("172.16.0.1") == :on_premises
    end

    test "172.31.0.0 upper bound" do
      assert EgressClassifier.locality("172.31.255.255") == :on_premises
    end

    test "172.15.x is NOT private (just below the range)" do
      assert EgressClassifier.locality("172.15.0.1") == :public
    end

    test "172.32.x is NOT private (just above the range)" do
      assert EgressClassifier.locality("172.32.0.1") == :public
    end

    test "link-local 169.254" do
      assert EgressClassifier.locality("169.254.1.1") == :on_premises
    end

    test "homelab ollama URL resolves on-premises" do
      assert EgressClassifier.locality("http://10.42.42.6:11434/api") == :on_premises
    end

    test "IPv6 unique-local fc00::/7" do
      assert EgressClassifier.locality("fc00::1") == :on_premises
    end

    test "IPv6 link-local fe80::/10" do
      assert EgressClassifier.locality("fe80::1") == :on_premises
    end

    test ".local mDNS hostname" do
      assert EgressClassifier.locality("printer.local") == :on_premises
    end

    test ".internal hostname" do
      assert EgressClassifier.locality("db.internal") == :on_premises
    end
  end

  describe "locality/1 — public" do
    test "a public hostname" do
      assert EgressClassifier.locality("api.anthropic.com") == :public
    end

    test "a public hostname in a URL" do
      assert EgressClassifier.locality("https://api.openai.com/v1/chat") == :public
    end

    test "a public IP literal" do
      assert EgressClassifier.locality("8.8.8.8") == :public
    end

    test "a bare hostname classifies public (no DNS resolution)" do
      assert EgressClassifier.locality("example.com") == :public
    end
  end

  describe "locality/1 — edge cases" do
    test "nil is conservatively public" do
      assert EgressClassifier.locality(nil) == :public
    end

    test "non-binary is conservatively public" do
      assert EgressClassifier.locality(:not_a_string) == :public
    end

    test "case-insensitive host" do
      assert EgressClassifier.locality("LOCALHOST") == :on_host
    end
  end
end
