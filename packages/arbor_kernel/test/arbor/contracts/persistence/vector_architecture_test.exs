defmodule Arbor.Contracts.Persistence.VectorArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @vector_sources ~w(
    vector_validation.ex
    vector_record.ex
    vector_operation.ex
    vector_receipt.ex
    vector_match.ex
  )

  test "vector transports remain independent of Ecto, Pgvector, Repo, schemas, and Memory" do
    root = Path.expand("../../../../lib/arbor/contracts/persistence", __DIR__)

    for filename <- @vector_sources do
      source = File.read!(Path.join(root, filename))

      refute source =~ "Ecto."
      refute source =~ "Pgvector"
      refute source =~ "Arbor.Persistence.Repo"
      refute source =~ "Arbor.Persistence.Schemas"
      refute source =~ "Arbor.Memory"
      refute source =~ "String.to_atom"
      refute source =~ ":erlang.binary_to_atom"
      refute source =~ ":erlang.list_to_atom"
    end

    mix_source = File.read!(Path.expand("../../../../mix.exs", __DIR__))
    refute mix_source =~ "{:ecto"
    refute mix_source =~ "{:pgvector"
    refute mix_source =~ "{:arbor_memory"
  end
end
