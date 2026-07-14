defmodule Arbor.Shell.StartupEpochTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.StartupEpoch

  @ns_a __MODULE__.NamespaceA
  @ns_b __MODULE__.NamespaceB

  setup do
    epochs = for _ <- 1..8, do: make_ref()

    on_exit(fn ->
      Enum.each(epochs, fn epoch ->
        StartupEpoch.clear(@ns_a, epoch)
        StartupEpoch.clear(@ns_b, epoch)
      end)
    end)

    {:ok, epochs: epochs}
  end

  describe "independent namespaces" do
    test "share an epoch reference without sharing bound state", %{epochs: [epoch | _]} do
      assert StartupEpoch.bind(@ns_a, epoch, {:term, :a}) == :bound
      assert StartupEpoch.status(@ns_a, epoch) == :bound
      assert StartupEpoch.status(@ns_b, epoch) == :unbound

      assert StartupEpoch.bind(@ns_b, epoch, {:term, :b}) == :bound
      assert StartupEpoch.bind(@ns_a, epoch, {:term, :a}) == :matched
      assert StartupEpoch.bind(@ns_b, epoch, {:term, :b}) == :matched

      assert StartupEpoch.poison(@ns_a, epoch) == :ok
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
      assert StartupEpoch.status(@ns_b, epoch) == :bound
    end
  end

  describe "bind transitions" do
    test "unbound bind retains an internal fingerprint and matches the same term", %{
      epochs: [epoch | _]
    } do
      term = %{path: "/secret/bindings", digest: :caller_supplied}

      assert StartupEpoch.status(@ns_a, epoch) == :unbound
      assert StartupEpoch.bind(@ns_a, epoch, term) == :bound
      assert StartupEpoch.status(@ns_a, epoch) == :bound
      assert StartupEpoch.bind(@ns_a, epoch, term) == :matched
      assert StartupEpoch.status(@ns_a, epoch) == :bound
    end

    test "different bound term poisons the epoch permanently", %{epochs: [epoch | _]} do
      assert StartupEpoch.bind(@ns_a, epoch, :first) == :bound
      assert StartupEpoch.bind(@ns_a, epoch, :second) == :poisoned
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
      assert StartupEpoch.bind(@ns_a, epoch, :first) == :poisoned
      assert StartupEpoch.bind(@ns_a, epoch, :second) == :poisoned
      assert StartupEpoch.seal(@ns_a, epoch, :unavailable) == :poisoned
    end
  end

  describe "seal transitions" do
    test "unbound seal closes unavailable and rejects later bind", %{epochs: [epoch | _]} do
      assert StartupEpoch.seal(@ns_a, epoch, :unavailable) == :sealed
      assert StartupEpoch.status(@ns_a, epoch) == {:sealed, :unavailable}
      assert StartupEpoch.bind(@ns_a, epoch, :any) == :sealed
      assert StartupEpoch.status(@ns_a, epoch) == {:sealed, :unavailable}
    end

    test "unbound seal closes unsupported and rejects later bind", %{epochs: [epoch | _]} do
      assert StartupEpoch.seal(@ns_a, epoch, :unsupported) == :sealed
      assert StartupEpoch.status(@ns_a, epoch) == {:sealed, :unsupported}
      assert StartupEpoch.bind(@ns_a, epoch, :any) == :sealed
    end

    test "changing sealed closed status poisons", %{epochs: [epoch | _]} do
      assert StartupEpoch.seal(@ns_a, epoch, :unsupported) == :sealed
      assert StartupEpoch.seal(@ns_a, epoch, :unavailable) == :poisoned
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
    end

    test "seal is a no-op against an already bound epoch", %{epochs: [epoch | _]} do
      assert StartupEpoch.bind(@ns_a, epoch, :term) == :bound
      assert StartupEpoch.seal(@ns_a, epoch, :unavailable) == :bound
      assert StartupEpoch.status(@ns_a, epoch) == :bound
      assert StartupEpoch.bind(@ns_a, epoch, :term) == :matched
    end
  end

  describe "poison permanence" do
    test "explicit poison remains poisoned across bind and seal", %{epochs: [epoch | _]} do
      assert StartupEpoch.bind(@ns_a, epoch, :term) == :bound
      assert StartupEpoch.poison(@ns_a, epoch) == :ok
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
      assert StartupEpoch.bind(@ns_a, epoch, :term) == :poisoned
      assert StartupEpoch.seal(@ns_a, epoch, :unsupported) == :poisoned
      assert StartupEpoch.poison(@ns_a, epoch) == :ok
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
    end
  end

  describe "nil epoch (no persistence)" do
    test "operations are deterministic and leave no residual state" do
      assert StartupEpoch.status(@ns_a, nil) == :unbound
      assert StartupEpoch.bind(@ns_a, nil, :term) == :bound
      assert StartupEpoch.status(@ns_a, nil) == :unbound
      assert StartupEpoch.bind(@ns_a, nil, :other) == :bound
      assert StartupEpoch.seal(@ns_a, nil, :unavailable) == :sealed
      assert StartupEpoch.status(@ns_a, nil) == :unbound
      assert StartupEpoch.poison(@ns_a, nil) == :ok
      assert StartupEpoch.status(@ns_a, nil) == :unbound
      assert StartupEpoch.clear(@ns_a, nil) == :ok
    end
  end

  describe "clear and new epoch" do
    test "clear restores unbound and a fresh epoch is independent", %{
      epochs: [epoch_a, epoch_b | _]
    } do
      assert StartupEpoch.bind(@ns_a, epoch_a, :term) == :bound
      assert StartupEpoch.clear(@ns_a, epoch_a) == :ok
      assert StartupEpoch.status(@ns_a, epoch_a) == :unbound
      assert StartupEpoch.bind(@ns_a, epoch_a, :other) == :bound

      assert StartupEpoch.poison(@ns_a, epoch_a) == :ok
      assert StartupEpoch.status(@ns_b, epoch_b) == :unbound
      assert StartupEpoch.bind(@ns_a, epoch_b, :fresh) == :bound
      assert StartupEpoch.status(@ns_a, epoch_a) == :poisoned
    end
  end

  describe "stored state never exposes raw terms" do
    test "persistent_term value is only a fingerprint or closed marker", %{
      epochs: [epoch | _]
    } do
      secret = {:binding, "/evil/path", %{sha256: "deadbeef", inode: 99}}

      assert StartupEpoch.bind(@ns_a, epoch, secret) == :bound

      stored = :persistent_term.get({StartupEpoch, @ns_a, epoch})
      assert stored == {:bound, fingerprint(secret)}
      refute inspect(stored) =~ "/evil/path"
      refute inspect(stored) =~ "deadbeef"
      refute match?({_, ^secret}, stored)

      assert StartupEpoch.clear(@ns_a, epoch) == :ok
      assert StartupEpoch.seal(@ns_a, epoch, :unavailable) == :sealed
      assert :persistent_term.get({StartupEpoch, @ns_a, epoch}) == {:sealed, :unavailable}
    end

    test "malformed stored state fails closed as poisoned", %{epochs: [epoch | _]} do
      :persistent_term.put({StartupEpoch, @ns_a, epoch}, {:bound, "too-short"})
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
      assert StartupEpoch.bind(@ns_a, epoch, :anything) == :poisoned

      :persistent_term.put({StartupEpoch, @ns_a, epoch}, :not_a_valid_epoch_value)
      assert StartupEpoch.status(@ns_a, epoch) == :poisoned
    end
  end

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end
end
