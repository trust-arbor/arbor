defmodule Arbor.Contracts.AI.CompactorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.AI.Compactor

  describe "behaviour definition" do
    test "module compiles and defines all callbacks" do
      assert {:module, Compactor} = Code.ensure_loaded(Compactor)

      callbacks = Compactor.behaviour_info(:callbacks)
      assert {:new, 1} in callbacks
      assert {:append, 2} in callbacks
      assert {:maybe_compact, 1} in callbacks
      assert {:llm_messages, 1} in callbacks
      assert {:full_transcript, 1} in callbacks
      assert {:stats, 1} in callbacks
      assert length(callbacks) == 6
    end
  end

  describe "mock implementation" do
    defmodule MockCompactor do
      @behaviour Arbor.Contracts.AI.Compactor

      defstruct messages: [], transcript: [], compact_count: 0

      @impl true
      def new(_opts), do: %__MODULE__{}

      @impl true
      def append(%__MODULE__{} = c, message) do
        %{c | messages: c.messages ++ [message], transcript: c.transcript ++ [message]}
      end

      @impl true
      def maybe_compact(%__MODULE__{} = c) do
        if length(c.messages) > 5 do
          %{c | messages: Enum.take(c.messages, -3), compact_count: c.compact_count + 1}
        else
          c
        end
      end

      @impl true
      def llm_messages(%__MODULE__{messages: msgs}), do: msgs

      @impl true
      def full_transcript(%__MODULE__{transcript: t}), do: t

      @impl true
      def stats(%__MODULE__{} = c) do
        %{
          total_messages: length(c.transcript),
          visible_messages: length(c.messages),
          compression_ratio:
            if(c.transcript != [],
              do: length(c.messages) / length(c.transcript),
              else: 1.0
            ),
          compactions_performed: c.compact_count
        }
      end
    end

    test "mock implements all callbacks" do
      c = MockCompactor.new([])
      assert %MockCompactor{} = c

      c = MockCompactor.append(c, %{role: :user, content: "hello"})
      assert length(MockCompactor.llm_messages(c)) == 1
      assert length(MockCompactor.full_transcript(c)) == 1

      stats = MockCompactor.stats(c)
      assert stats.total_messages == 1
      assert stats.visible_messages == 1
      assert stats.compression_ratio == 1.0
      assert stats.compactions_performed == 0
    end

    test "compaction preserves full transcript" do
      c = MockCompactor.new([])

      c =
        Enum.reduce(1..8, c, fn i, acc ->
          MockCompactor.append(acc, %{role: :user, content: "msg #{i}"})
        end)

      c = MockCompactor.maybe_compact(c)

      # Full transcript preserved
      assert length(MockCompactor.full_transcript(c)) == 8
      # LLM messages trimmed
      assert length(MockCompactor.llm_messages(c)) == 3
      assert MockCompactor.stats(c).compactions_performed == 1
    end
  end
end
