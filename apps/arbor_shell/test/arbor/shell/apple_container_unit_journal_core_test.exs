defmodule Arbor.Shell.AppleContainerUnitJournalCoreTest do
  @moduledoc """
  Exhaustive pure tests for the Apple Container unit-intent journal CRC core.

  No IO, processes, or time — all tokens and timestamps are injected fixtures.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerUnitJournalCore, as: Core

  @moduletag :fast

  @hex32_a String.duplicate("a", 32)
  @hex32_b String.duplicate("b", 32)
  @hex32_c String.duplicate("c", 32)
  @hex32_d String.duplicate("d", 32)

  @token_a String.duplicate("1", 64)
  @token_b String.duplicate("2", 64)
  @token_c String.duplicate("3", 64)
  @token_d String.duplicate("4", 64)

  @unit_a "arbor-v1-#{@hex32_a}"
  @unit_b "arbor-v1-#{@hex32_b}"
  @unit_c "arbor-v1-#{@hex32_c}"
  @unit_d "arbor-v1-#{@hex32_d}"

  @exec_a "exec-alpha-1"
  @exec_b "exec-beta-2"
  @exec_c "exec-gamma-3"
  @exec_d "exec-delta-4"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unit_name(hex32) when is_binary(hex32) and byte_size(hex32) == 32 do
    "arbor-v1-" <> hex32
  end

  defp token(hex64) when is_binary(hex64) and byte_size(hex64) == 64, do: hex64

  defp token_from_n(n) when is_integer(n) and n >= 0 do
    # Deterministic 64-hex token from a nonnegative integer (no crypto/rand).
    base = Integer.to_string(n, 16) |> String.downcase()
    String.pad_leading(base, 64, "0")
  end

  defp hex32_from_n(n) when is_integer(n) and n >= 0 do
    base = Integer.to_string(n, 16) |> String.downcase()
    String.pad_leading(base, 32, "0")
  end

  defp reserve_attrs(opts) do
    %{
      unit_name: Keyword.fetch!(opts, :unit_name),
      execution_id: Keyword.fetch!(opts, :execution_id),
      token: Keyword.fetch!(opts, :token),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, 1_700_000_000_000)
    }
  end

  defp empty! do
    assert {:ok, state} = Core.new()
    state
  end

  defp reserve!(state, opts) do
    assert {:ok, new_state, effects} = Core.reserve(state, reserve_attrs(opts))
    {new_state, effects}
  end

  defp snapshot_record(opts) do
    %{
      "unit_name" => Keyword.fetch!(opts, :unit_name),
      "execution_id" => Keyword.fetch!(opts, :execution_id),
      "token" => Keyword.fetch!(opts, :token),
      "reserved_at_ms" => Keyword.get(opts, :reserved_at_ms, 1_700_000_000_000)
    }
  end

  # ---------------------------------------------------------------------------
  # new/0 and empty construction
  # ---------------------------------------------------------------------------

  describe "new/0 empty journal" do
    test "constructs schema_version 1, generation 0, empty active" do
      assert {:ok, state} = Core.new()
      assert state.schema_version == 1
      assert state.generation == 0
      assert state.by_name == %{}

      shown = Core.show(state)
      assert shown == %{"schema_version" => 1, "generation" => 0, "active" => []}
      assert Jason.encode!(shown)
    end
  end

  # ---------------------------------------------------------------------------
  # Round trip
  # ---------------------------------------------------------------------------

  describe "round trip" do
    test "show/1 → new/1 reconstructs identical show output" do
      state = empty!()

      {state, _} =
        reserve!(state,
          unit_name: @unit_b,
          execution_id: @exec_b,
          token: @token_b,
          reserved_at_ms: 20
        )

      {state, _} =
        reserve!(state,
          unit_name: @unit_a,
          execution_id: @exec_a,
          token: @token_a,
          reserved_at_ms: 10
        )

      shown = Core.show(state)
      assert {:ok, restored} = Core.new(shown)
      assert Core.show(restored) == shown
      assert restored.generation == state.generation
      assert map_size(restored.by_name) == 2
    end

    test "empty snapshot round trip" do
      assert {:ok, state} = Core.new(%{"schema_version" => 1, "generation" => 0, "active" => []})
      assert Core.show(state) == %{"schema_version" => 1, "generation" => 0, "active" => []}
    end

    test "atom-keyed snapshot round trip" do
      snapshot = %{
        schema_version: 1,
        generation: 3,
        active: [
          %{
            unit_name: @unit_a,
            execution_id: @exec_a,
            token: @token_a,
            reserved_at_ms: 42
          }
        ]
      }

      assert {:ok, state} = Core.new(snapshot)
      assert state.generation == 3

      assert Core.show(state)["active"] == [
               %{
                 "unit_name" => @unit_a,
                 "execution_id" => @exec_a,
                 "token" => @token_a,
                 "reserved_at_ms" => 42
               }
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Atom / string inputs
  # ---------------------------------------------------------------------------

  describe "atom and string inputs" do
    test "reserve accepts string-keyed attrs" do
      state = empty!()

      attrs = %{
        "unit_name" => @unit_a,
        "execution_id" => @exec_a,
        "token" => @token_a,
        "reserved_at_ms" => 99
      }

      assert {:ok, new_state, [{:persist_snapshot, snap}]} = Core.reserve(state, attrs)
      assert new_state.generation == 1

      assert snap["active"] == [
               %{
                 "unit_name" => @unit_a,
                 "execution_id" => @exec_a,
                 "token" => @token_a,
                 "reserved_at_ms" => 99
               }
             ]
    end

    test "new/1 accepts mixed atom/string keys across different fields" do
      snapshot = %{
        "schema_version" => 1,
        :generation => 1,
        "active" => [
          %{
            :unit_name => @unit_a,
            "execution_id" => @exec_a,
            :token => @token_a,
            "reserved_at_ms" => 1
          }
        ]
      }

      assert {:ok, state} = Core.new(snapshot)
      assert state.generation == 1
      assert Map.has_key?(state.by_name, @unit_a)
    end

    test "complete accepts validated binary name and token" do
      state = empty!()

      {state, _} =
        reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)

      assert {:ok, done, [{:persist_snapshot, snap}]} = Core.complete(state, @unit_a, @token_a)
      assert done.generation == 2
      assert snap["active"] == []
      assert done.by_name == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate aliases / unknown fields
  # ---------------------------------------------------------------------------

  describe "duplicate aliases and unknown fields" do
    test "rejects duplicate journal key aliases" do
      snapshot = %{
        :schema_version => 1,
        "schema_version" => 1,
        :generation => 0,
        :active => []
      }

      assert {:error, {:duplicate_key_alias, :journal, :schema_version}} = Core.new(snapshot)
    end

    test "rejects duplicate record key aliases in active" do
      snapshot = %{
        schema_version: 1,
        generation: 0,
        active: [
          %{
            :unit_name => @unit_a,
            "unit_name" => @unit_a,
            :execution_id => @exec_a,
            :token => @token_a,
            :reserved_at_ms => 1
          }
        ]
      }

      assert {:error, {:duplicate_key_alias, :record, :unit_name}} = Core.new(snapshot)
    end

    test "rejects duplicate reserve attr aliases" do
      state = empty!()

      attrs = %{
        :unit_name => @unit_a,
        "unit_name" => @unit_a,
        :execution_id => @exec_a,
        :token => @token_a,
        :reserved_at_ms => 1
      }

      original = Core.show(state)
      assert {:error, {:duplicate_key_alias, :reserve, :unit_name}} = Core.reserve(state, attrs)
      assert Core.show(state) == original
    end

    test "rejects unknown journal keys" do
      assert {:error, {:unsupported_keys, :journal}} =
               Core.new(%{
                 schema_version: 1,
                 generation: 0,
                 active: [],
                 extra: true
               })
    end

    test "rejects unknown record keys on reserve" do
      state = empty!()
      original = Core.show(state)

      attrs =
        Map.put(
          reserve_attrs(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
          :path,
          "/tmp"
        )

      assert {:error, {:unsupported_keys, :reserve}} = Core.reserve(state, attrs)
      assert Core.show(state) == original
    end

    test "rejects unknown keys inside persisted active records" do
      assert {:error, {:unsupported_keys, :record}} =
               Core.new(%{
                 schema_version: 1,
                 generation: 1,
                 active: [
                   Map.put(
                     %{
                       unit_name: @unit_a,
                       execution_id: @exec_a,
                       token: @token_a,
                       reserved_at_ms: 1
                     },
                     :argv,
                     []
                   )
                 ]
               })
    end

    test "rejects authority-like and process fields" do
      forbidden = [
        :path,
        :argv,
        :env,
        :pid,
        :ref,
        :callback,
        :metadata,
        :authority,
        :capability
      ]

      state = empty!()
      original = Core.show(state)

      for key <- forbidden do
        attrs =
          Map.put(
            reserve_attrs(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
            key,
            "x"
          )

        assert {:error, {:unsupported_keys, :reserve}} = Core.reserve(state, attrs)
        assert Core.show(state) == original
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Every record bound
  # ---------------------------------------------------------------------------

  describe "record field bounds" do
    test "unit_name must be arbor-v1- plus exactly 32 lowercase hex" do
      state = empty!()
      original = Core.show(state)

      bad_names = [
        "arbor-v1-" <> String.duplicate("a", 31),
        "arbor-v1-" <> String.duplicate("a", 33),
        "arbor-v1-" <> String.duplicate("A", 32),
        "arbor-v1-" <> String.duplicate("g", 32),
        "arbor-v0-" <> @hex32_a,
        "other-v1-" <> @hex32_a,
        "arbor-v1-" <> @hex32_a <> "0",
        "",
        "arbor-v1",
        123
      ]

      for name <- bad_names do
        assert {:error, :invalid_unit_name} =
                 Core.reserve(
                   state,
                   reserve_attrs(unit_name: name, execution_id: @exec_a, token: @token_a)
                 )

        assert Core.show(state) == original
      end
    end

    test "token must be exactly 64 lowercase hex" do
      state = empty!()
      original = Core.show(state)

      bad_tokens = [
        String.duplicate("a", 63),
        String.duplicate("a", 65),
        String.duplicate("A", 64),
        String.duplicate("g", 64),
        "",
        1,
        nil
      ]

      for tok <- bad_tokens do
        assert {:error, :invalid_token} =
                 Core.reserve(
                   state,
                   reserve_attrs(unit_name: @unit_a, execution_id: @exec_a, token: tok)
                 )

        assert Core.show(state) == original
      end
    end

    test "execution_id UTF-8, length 1..256, no slash/backslash/NUL/control/whitespace" do
      state = empty!()
      original = Core.show(state)

      bad_ids = [
        "",
        String.duplicate("x", 257),
        "has/slash",
        "has\\backslash",
        "has\0nul",
        "has space",
        "has\ttab",
        "has\nnewline",
        "has\rreturn",
        "ctrl\x01",
        "del\x7F",
        # invalid UTF-8
        <<0xC3, 0x28>>,
        12,
        nil,
        :atom
      ]

      for id <- bad_ids do
        assert {:error, :invalid_execution_id} =
                 Core.reserve(
                   state,
                   reserve_attrs(unit_name: @unit_a, execution_id: id, token: @token_a)
                 )

        assert Core.show(state) == original
      end

      # Boundary lengths accepted
      for id <- ["x", String.duplicate("y", 256)] do
        s = empty!()

        assert {:ok, _, _} =
                 Core.reserve(
                   s,
                   reserve_attrs(unit_name: @unit_a, execution_id: id, token: @token_a)
                 )
      end
    end

    test "reserved_at_ms must be nonnegative integer" do
      state = empty!()
      original = Core.show(state)

      for ms <- [-1, 1.5, "0", nil, :now] do
        assert {:error, :invalid_reserved_at_ms} =
                 Core.reserve(
                   state,
                   reserve_attrs(
                     unit_name: @unit_a,
                     execution_id: @exec_a,
                     token: @token_a,
                     reserved_at_ms: ms
                   )
                 )

        assert Core.show(state) == original
      end

      assert {:ok, _, _} =
               Core.reserve(
                 state,
                 reserve_attrs(
                   unit_name: @unit_a,
                   execution_id: @exec_a,
                   token: @token_a,
                   reserved_at_ms: 0
                 )
               )
    end

    test "table: valid unit names and tokens" do
      cases = [
        {String.duplicate("0", 32), String.duplicate("f", 64)},
        {String.duplicate("abcdef0123456789", 2), String.duplicate("0123456789abcdef", 4)},
        {@hex32_a, @token_a}
      ]

      for {hex, tok} <- cases do
        state = empty!()
        name = unit_name(hex)

        assert {:ok, new_state, [{:persist_snapshot, snap}]} =
                 Core.reserve(
                   state,
                   reserve_attrs(unit_name: name, execution_id: "e-#{hex}", token: token(tok))
                 )

        assert hd(snap["active"])["unit_name"] == name
        assert new_state.generation == 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Capacity 1,024
  # ---------------------------------------------------------------------------

  describe "capacity" do
    test "accepts exactly 1,024 active records and rejects the next" do
      max = Core.limits().max_active
      assert max == 1_024

      # Build a full snapshot without 1,024 sequential reserve calls in the
      # assertion path (construct via new/1 for speed).
      active =
        for i <- 0..(max - 1) do
          snapshot_record(
            unit_name: unit_name(hex32_from_n(i)),
            execution_id: "exec-#{i}",
            token: token_from_n(i),
            reserved_at_ms: i
          )
        end

      assert {:ok, full} =
               Core.new(%{
                 "schema_version" => 1,
                 "generation" => max,
                 "active" => active
               })

      assert map_size(full.by_name) == max
      assert length(Core.recovery_entries(full)) == max

      original = Core.show(full)

      assert {:error, :journal_at_capacity} =
               Core.reserve(
                 full,
                 reserve_attrs(
                   unit_name: unit_name(hex32_from_n(max)),
                   execution_id: "exec-overflow",
                   token: token_from_n(max)
                 )
               )

      assert Core.show(full) == original
    end

    test "new/1 rejects active lists larger than capacity" do
      max = Core.limits().max_active

      active =
        for i <- 0..max do
          snapshot_record(
            unit_name: unit_name(hex32_from_n(i)),
            execution_id: "exec-#{i}",
            token: token_from_n(i)
          )
        end

      assert {:error, :journal_at_capacity} =
               Core.new(%{"schema_version" => 1, "generation" => 0, "active" => active})
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate name / execution / token
  # ---------------------------------------------------------------------------

  describe "duplicate identity fields" do
    test "reserve rejects duplicate unit_name, execution_id, and token" do
      state = empty!()

      {state, _} =
        reserve!(state,
          unit_name: @unit_a,
          execution_id: @exec_a,
          token: @token_a,
          reserved_at_ms: 1
        )

      original = Core.show(state)

      assert {:error, :duplicate_unit_name} =
               Core.reserve(
                 state,
                 reserve_attrs(
                   unit_name: @unit_a,
                   execution_id: @exec_b,
                   token: @token_b
                 )
               )

      assert {:error, :duplicate_execution_id} =
               Core.reserve(
                 state,
                 reserve_attrs(
                   unit_name: @unit_b,
                   execution_id: @exec_a,
                   token: @token_b
                 )
               )

      assert {:error, :duplicate_token} =
               Core.reserve(
                 state,
                 reserve_attrs(
                   unit_name: @unit_b,
                   execution_id: @exec_b,
                   token: @token_a
                 )
               )

      assert Core.show(state) == original
    end

    test "new/1 rejects duplicate unit_name, execution_id, token in active" do
      base = %{
        unit_name: @unit_a,
        execution_id: @exec_a,
        token: @token_a,
        reserved_at_ms: 1
      }

      assert {:error, :duplicate_unit_name} =
               Core.new(%{
                 schema_version: 1,
                 generation: 2,
                 active: [base, %{base | execution_id: @exec_b, token: @token_b}]
               })

      assert {:error, :duplicate_execution_id} =
               Core.new(%{
                 schema_version: 1,
                 generation: 2,
                 active: [
                   base,
                   %{
                     unit_name: @unit_b,
                     execution_id: @exec_a,
                     token: @token_b,
                     reserved_at_ms: 2
                   }
                 ]
               })

      assert {:error, :duplicate_token} =
               Core.new(%{
                 schema_version: 1,
                 generation: 2,
                 active: [
                   base,
                   %{
                     unit_name: @unit_b,
                     execution_id: @exec_b,
                     token: @token_a,
                     reserved_at_ms: 2
                   }
                 ]
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Exact completion
  # ---------------------------------------------------------------------------

  describe "exact completion" do
    test "removes only the matching unit_name + token" do
      state = empty!()

      {state, _} =
        reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)

      {state, _} =
        reserve!(state, unit_name: @unit_b, execution_id: @exec_b, token: @token_b)

      assert {:ok, state, [{:persist_snapshot, snap}]} =
               Core.complete(state, @unit_a, @token_a)

      assert state.generation == 3
      assert Map.keys(state.by_name) == [@unit_b]
      assert length(snap["active"]) == 1
      assert hd(snap["active"])["unit_name"] == @unit_b
      assert snap == Core.show(state)
    end

    test "effect snapshot equals show after complete" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      assert {:ok, new_state, [effect]} = Core.complete(state, @unit_a, @token_a)
      assert effect == {:persist_snapshot, Core.show(new_state)}
    end
  end

  # ---------------------------------------------------------------------------
  # Replay / wrong-token immutability
  # ---------------------------------------------------------------------------

  describe "replay and wrong-token immutability" do
    test "wrong token fails closed without changing state" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      original = Core.show(state)

      assert {:error, :token_mismatch} = Core.complete(state, @unit_a, @token_b)
      assert Core.show(state) == original
      assert map_size(state.by_name) == 1
    end

    test "unknown unit_name fails closed" do
      state = empty!()
      original = Core.show(state)

      assert {:error, :unknown_unit_name} = Core.complete(state, @unit_a, @token_a)
      assert Core.show(state) == original
    end

    test "replay after successful complete fails closed" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      assert {:ok, state, _} = Core.complete(state, @unit_a, @token_a)
      original = Core.show(state)

      assert {:error, :unknown_unit_name} = Core.complete(state, @unit_a, @token_a)
      assert Core.show(state) == original
      assert state.generation == 2
    end

    test "malformed complete inputs fail closed" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      original = Core.show(state)

      assert {:error, :invalid_unit_name} = Core.complete(state, "not-a-unit", @token_a)
      assert {:error, :invalid_token} = Core.complete(state, @unit_a, "short")
      assert {:error, :invalid_unit_name} = Core.complete(state, nil, @token_a)
      assert {:error, :invalid_token} = Core.complete(state, @unit_a, nil)
      assert Core.show(state) == original
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic ordering
  # ---------------------------------------------------------------------------

  describe "deterministic ordering" do
    test "show and recovery_entries sort by unit_name bytewise" do
      # Insert in reverse lexicographic order of unit names.
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_d, execution_id: @exec_d, token: @token_d)
      {state, _} = reserve!(state, unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      {state, _} = reserve!(state, unit_name: @unit_c, execution_id: @exec_c, token: @token_c)
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)

      expected_order = Enum.sort([@unit_a, @unit_b, @unit_c, @unit_d])
      assert expected_order == [@unit_a, @unit_b, @unit_c, @unit_d]

      shown_names = Enum.map(Core.show(state)["active"], & &1["unit_name"])
      assert shown_names == expected_order

      recovery_names = Enum.map(Core.recovery_entries(state), & &1.unit_name)
      assert recovery_names == expected_order

      # recovery never claims absence/safe-delete — only lists actives
      assert length(Core.recovery_entries(state)) == 4
    end

    test "show is canonical and JSON-encodable" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)

      a = Core.show(state)
      b = Core.show(state)
      assert a == b
      assert Jason.encode!(a) == Jason.encode!(b)
    end
  end

  # ---------------------------------------------------------------------------
  # Generation and effect equality
  # ---------------------------------------------------------------------------

  describe "generation and effect equality" do
    test "reserve increments generation exactly once and effect matches show" do
      state = empty!()
      assert state.generation == 0

      assert {:ok, state1, effects1} =
               Core.reserve(
                 state,
                 reserve_attrs(unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
               )

      assert state1.generation == 1
      assert effects1 == [{:persist_snapshot, Core.show(state1)}]
      assert state.generation == 0

      assert {:ok, state2, effects2} =
               Core.reserve(
                 state1,
                 reserve_attrs(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
               )

      assert state2.generation == 2
      assert effects2 == [{:persist_snapshot, Core.show(state2)}]
    end

    test "complete increments generation exactly once" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      assert state.generation == 1

      assert {:ok, done, effects} = Core.complete(state, @unit_a, @token_a)
      assert done.generation == 2
      assert effects == [{:persist_snapshot, Core.show(done)}]
      assert state.generation == 1
    end

    test "failed transitions do not increment generation" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      gen = state.generation

      assert {:error, _} =
               Core.reserve(
                 state,
                 reserve_attrs(unit_name: @unit_a, execution_id: @exec_b, token: @token_b)
               )

      assert {:error, _} = Core.complete(state, @unit_a, @token_b)
      assert {:error, _} = Core.complete(state, @unit_b, @token_a)
      assert state.generation == gen
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed persisted state
  # ---------------------------------------------------------------------------

  describe "malformed persisted state" do
    test "rejects non-map input" do
      assert {:error, :invalid_journal} = Core.new("nope")
      assert {:error, :invalid_journal} = Core.new(nil)
      assert {:error, :invalid_journal} = Core.new([])
      assert {:error, :invalid_journal} = Core.new(1)
    end

    test "rejects unsupported schema versions" do
      assert {:error, {:unsupported_schema_version, 2}} =
               Core.new(%{schema_version: 2, generation: 0, active: []})

      assert {:error, {:unsupported_schema_version, 0}} =
               Core.new(%{schema_version: 0, generation: 0, active: []})

      assert {:error, :invalid_schema_version} =
               Core.new(%{schema_version: "1", generation: 0, active: []})
    end

    test "rejects missing required journal fields" do
      assert {:error, :missing_schema_version} = Core.new(%{generation: 0, active: []})
      assert {:error, :missing_generation} = Core.new(%{schema_version: 1, active: []})
      assert {:error, :missing_active} = Core.new(%{schema_version: 1, generation: 0})
    end

    test "rejects invalid generation" do
      assert {:error, :invalid_generation} =
               Core.new(%{schema_version: 1, generation: -1, active: []})

      assert {:error, :invalid_generation} =
               Core.new(%{schema_version: 1, generation: 1.0, active: []})

      assert {:error, :invalid_generation} =
               Core.new(%{schema_version: 1, generation: "0", active: []})
    end

    test "rejects invalid active collection" do
      assert {:error, :invalid_active} =
               Core.new(%{schema_version: 1, generation: 0, active: %{}})

      assert {:error, :invalid_record} =
               Core.new(%{schema_version: 1, generation: 0, active: ["not-a-map"]})
    end

    test "rejects malformed records inside active" do
      assert {:error, :missing_token} =
               Core.new(%{
                 schema_version: 1,
                 generation: 1,
                 active: [
                   %{
                     unit_name: @unit_a,
                     execution_id: @exec_a,
                     reserved_at_ms: 1
                   }
                 ]
               })

      assert {:error, :invalid_unit_name} =
               Core.new(%{
                 schema_version: 1,
                 generation: 1,
                 active: [
                   %{
                     unit_name: "bad",
                     execution_id: @exec_a,
                     token: @token_a,
                     reserved_at_ms: 1
                   }
                 ]
               })
    end

    test "operations on invalid state fail closed" do
      assert {:error, :invalid_journal_state} =
               Core.reserve(
                 %{},
                 reserve_attrs(unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
               )

      assert {:error, :invalid_journal_state} = Core.complete(%{}, @unit_a, @token_a)
      assert {:error, :invalid_journal_state} = Core.recovery_entries(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # recovery_entries contract
  # ---------------------------------------------------------------------------

  describe "recovery_entries/1" do
    test "returns all actives sorted and never mutates" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_c, execution_id: @exec_c, token: @token_c)
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)

      original = Core.show(state)
      entries = Core.recovery_entries(state)

      assert Enum.map(entries, & &1.unit_name) == [@unit_a, @unit_c]

      assert Enum.all?(entries, fn e ->
               Map.keys(e) |> Enum.sort() ==
                 [:execution_id, :reserved_at_ms, :token, :unit_name]
             end)

      assert Core.show(state) == original
    end

    test "empty journal yields empty recovery list" do
      assert Core.recovery_entries(empty!()) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths leave original immutable
  # ---------------------------------------------------------------------------

  describe "immutability on every error path" do
    test "reserve errors leave original map unchanged" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      freeze = :erlang.term_to_binary(state)

      errors = [
        Core.reserve(
          state,
          reserve_attrs(unit_name: @unit_a, execution_id: @exec_b, token: @token_b)
        ),
        Core.reserve(
          state,
          reserve_attrs(unit_name: @unit_b, execution_id: @exec_a, token: @token_b)
        ),
        Core.reserve(
          state,
          reserve_attrs(unit_name: @unit_b, execution_id: @exec_b, token: @token_a)
        ),
        Core.reserve(state, %{unit_name: @unit_b}),
        Core.reserve(state, "nope")
      ]

      assert Enum.all?(errors, &match?({:error, _}, &1))
      assert :erlang.term_to_binary(state) == freeze
    end

    test "complete errors leave original map unchanged" do
      state = empty!()
      {state, _} = reserve!(state, unit_name: @unit_a, execution_id: @exec_a, token: @token_a)
      freeze = :erlang.term_to_binary(state)

      errors = [
        Core.complete(state, @unit_a, @token_b),
        Core.complete(state, @unit_b, @token_a),
        Core.complete(state, "bad", @token_a),
        Core.complete(state, @unit_a, "bad")
      ]

      assert Enum.all?(errors, &match?({:error, _}, &1))
      assert :erlang.term_to_binary(state) == freeze
    end
  end

  # ---------------------------------------------------------------------------
  # Purity surface (source-level)
  # ---------------------------------------------------------------------------

  describe "purity" do
    test "core source contains no impure calls" do
      path =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_journal_core.ex",
          __DIR__
        )

      src = File.read!(path)

      forbidden = [
        ~r/DateTime\.utc_now/,
        ~r/System\.(monotonic|os|system)_time/,
        ~r/:rand\./,
        ~r/:erlang\.unique_integer/,
        ~r/make_ref/,
        ~r/Application\.get_env/,
        ~r/GenServer\./,
        ~r/Repo\./,
        ~r/:ets\./,
        ~r/Logger\./,
        ~r/File\./,
        ~r/:crypto\.(strong_rand_bytes|rand_seed)/
      ]

      for re <- forbidden do
        refute Regex.match?(re, src), "impure pattern #{inspect(re)} found in journal core"
      end
    end
  end
end
