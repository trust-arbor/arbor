defmodule Arbor.Orchestrator.Conformance.Matrix do
  @moduledoc """
  Spec conformance matrix anchored to the three Attractor repository specs.

  Status values:
  - `:implemented` -> behavior exists and has direct tests
  - `:partial` -> scaffold exists, more coverage/behavior needed
  - `:pending` -> not implemented yet
  """

  @matrix %{
    attractor: [
      %{
        id: "11.1",
        title: "DOT parsing",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance111Test"
      },
      %{
        id: "11.2",
        title: "Validation and linting",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance112Test"
      },
      %{
        id: "11.3",
        title: "Execution engine",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance113Test"
      },
      %{
        id: "11.4",
        title: "Goal gate enforcement",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance114Test"
      },
      %{
        id: "11.5",
        title: "Retry logic",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance115Test"
      },
      %{
        id: "3.6",
        title: "Retry policy/backoff",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance36Test"
      },
      %{
        id: "3.7",
        title: "Failure routing",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance37Test"
      },
      %{
        id: "11.6",
        title: "Node handlers",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance116Test"
      },
      %{
        id: "4.8",
        title: "Parallel handler",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance48Test"
      },
      %{
        id: "4.9",
        title: "Fan-in handler",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance49Test"
      },
      %{
        id: "4.11",
        title: "Manager loop handler",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance411Test"
      },
      %{
        id: "4.12",
        title: "Custom handlers",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance412Test"
      },
      %{
        id: "11.7",
        title: "State and context",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance117Test"
      },
      %{
        id: "5.4",
        title: "Context fidelity",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance54Test"
      },
      %{
        id: "5.3",
        title: "Checkpoint and resume",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance53Test"
      },
      %{
        id: "5.6",
        title: "Run directory structure",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance56Test"
      },
      %{
        id: "9.6",
        title: "Observability/events",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance96Test"
      },
      %{
        id: "11.9",
        title: "Condition expressions",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance119Test"
      },
      %{
        id: "11.8",
        title: "Human-in-the-loop",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance118Test"
      },
      %{
        id: "11.10",
        title: "Model stylesheet",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance1110Test"
      },
      %{
        id: "11.11",
        title: "Transforms/extensibility",
        status: :implemented,
        module: "Arbor.Orchestrator.Conformance1111Test"
      },
      %{
        id: "11.12",
        title: "Cross-feature parity matrix",
        status: :implemented,
        module: "Arbor.Orchestrator.CrossFeatureMatrixTest"
      }
    ],
    unified_llm: [
      %{
        id: "8.1",
        title: "Core infrastructure",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance81Test"
      },
      %{
        id: "8.2",
        title: "Provider adapters",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance82Test"
      },
      %{
        id: "8.3",
        title: "Message & content model",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance83Test"
      },
      %{
        id: "8.4",
        title: "Generation",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance84Test"
      },
      %{
        id: "8.5",
        title: "Reasoning tokens",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance85Test"
      },
      %{
        id: "4.2",
        title: "Streaming",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance42Test"
      },
      %{
        id: "8.7",
        title: "Tool calling",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance87Test"
      },
      %{
        id: "8.8",
        title: "Error handling/retry",
        status: :implemented,
        module: "Arbor.Orchestrator.UnifiedLLM.Conformance88Test"
      }
    ]
  }

  @spec_docs %{
    attractor: "specs/attractor/attractor-spec.md",
    unified_llm: "specs/attractor/unified-llm-spec.md"
  }

  @spec items() :: map()
  def items do
    Enum.into(@matrix, %{}, fn {spec, rows} ->
      doc = Map.fetch!(@spec_docs, spec)

      with_meta =
        Enum.map(rows, fn row ->
          row
          |> Map.put(:spec_doc, doc)
          |> Map.put(:spec_section, row.id)
        end)

      {spec, with_meta}
    end)
  end

  @spec summary() :: map()
  def summary do
    matrix = items()

    totals =
      matrix
      |> Enum.map(fn {spec, rows} ->
        counts =
          Enum.reduce(rows, %{implemented: 0, partial: 0, pending: 0}, fn row, acc ->
            Map.update!(acc, row.status, &(&1 + 1))
          end)

        {spec, Map.put(counts, :total, length(rows))}
      end)
      |> Map.new()

    %{by_spec: totals, items: matrix}
  end
end
