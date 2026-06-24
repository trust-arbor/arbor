defmodule Arbor.Cartographer.ApplicationSecurityTest do
  # Manages the global Cartographer supervision tree; cannot be async.
  use ExUnit.Case, async: false

  alias Arbor.Cartographer
  alias Arbor.Cartographer.{CapabilityRegistry, Scout}

  @moduletag :fast

  # M5 security regression (SECURITY_REVIEW 2026-02-16):
  # "Unsafe String.to_atom/1 in Cartographer CARTOGRAPHER_CUSTOM_TAGS parsing."
  #
  # An operator-controlled (but attacker-influenceable) env var was mapped with
  # `String.to_atom/1`, allowing arbitrary atom creation (atom-table exhaustion
  # DoS). The fix parses CARTOGRAPHER_CUSTOM_TAGS through `String.to_existing_atom`
  # with a rescue that DROPS unknown tags (with a warning) — so a tag string that
  # is not already an atom can never mint a new atom.
  #
  # This drives the public `Arbor.Cartographer.Application.start/2` callback (the
  # real boot path that reads the env var) and asserts the invariant behaviorally.
  #
  # Red-proof: revert `add_custom_tags/1` to `Enum.map(&String.to_atom/1)` and the
  # unknown tag is interned -> `String.to_existing_atom/1` stops raising -> RED.
  describe "M5 security regression — CARTOGRAPHER_CUSTOM_TAGS does not mint atoms" do
    setup do
      stop_tree()
      Process.sleep(100)

      on_exit(fn ->
        System.delete_env("CARTOGRAPHER_CUSTOM_TAGS")
        stop_tree()
        Process.sleep(50)
      end)

      :ok
    end

    test "an unknown tag from the env var is dropped and never interned as an atom" do
      # A known atom that already exists and should survive parsing.
      _ensure_exists = :test_mode

      unknown = "carto_unknown_tag_#{System.unique_integer([:positive])}"

      # Precondition: the unknown tag must not already be an atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      System.put_env("CARTOGRAPHER_CUSTOM_TAGS", "test_mode,#{unknown}")

      {:ok, sup} = Arbor.Cartographer.Application.start(:normal, [])

      try do
        wait_for_registration(20)

        {:ok, tags} = Cartographer.my_capabilities()

        # Known tag survived the existing-atom conversion...
        assert :test_mode in tags

        # ...and the unknown tag was dropped (never registered as a capability).
        refute Enum.any?(tags, fn t -> Atom.to_string(t) == unknown end)

        # The core invariant: the untrusted tag string was NOT interned as an atom.
        assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      after
        Supervisor.stop(sup, :normal, 5000)
      end
    end
  end

  defp wait_for_registration(0), do: :ok

  defp wait_for_registration(attempts) do
    case CapabilityRegistry.get(Node.self()) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        Process.sleep(100)
        wait_for_registration(attempts - 1)
    end
  end

  defp stop_tree do
    safe_stop(Arbor.Cartographer.Supervisor)
    safe_stop(Scout)
    safe_stop(CapabilityRegistry)
  end

  defp safe_stop(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Process.unlink(pid)
          Supervisor.stop(pid, :normal, 5000)
        catch
          :exit, _ -> :ok
          _, _ -> :ok
        end
    end
  rescue
    _ -> :ok
  end
end
