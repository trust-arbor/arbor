defmodule Arbor.Orchestrator.Eval.Sample do
  @moduledoc "A single evaluation sample with input, expected output, and metadata."

  @type t :: %__MODULE__{
          id: String.t(),
          input: any(),
          expected: any(),
          metadata: map()
        }

  @derive Jason.Encoder
  defstruct id: "",
            input: nil,
            expected: nil,
            metadata: %{}

  @doc "Build a Sample from a decoded JSON map."
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: Map.get(map, "id", generate_id()),
      input: Map.get(map, "input"),
      expected: Map.get(map, "expected"),
      metadata: Map.get(map, "metadata", %{})
    }
  end

  @doc "Parse a single JSONL line into a Sample."
  def from_jsonl_line(line) when is_binary(line) do
    line
    |> String.trim()
    |> Jason.decode!()
    |> from_map()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
