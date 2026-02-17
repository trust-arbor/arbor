defmodule Arbor.Orchestrator.Engine.Fidelity do
  @moduledoc false

  alias Arbor.Orchestrator.Engine.Context

  @valid_modes ~w(full truncate compact summary:low summary:medium summary:high)

  @spec resolve(map(), map() | nil, map(), Context.t()) :: %{
          mode: String.t(),
          thread_id: String.t() | nil,
          explicit?: boolean()
        }
  def resolve(node, incoming_edge, graph, context) do
    explicit_mode =
      first_present([
        get_attr(incoming_edge, "fidelity"),
        get_attr(node, "fidelity"),
        Map.get(graph.attrs, "default_fidelity")
      ])

    mode = normalize_mode(explicit_mode || "compact")

    thread_id =
      if mode == "full" do
        first_present([
          get_attr(node, "thread_id"),
          get_attr(incoming_edge, "thread_id"),
          Map.get(graph.attrs, "thread_id"),
          first_class(node),
          Context.get(context, "last_stage")
        ])
      else
        nil
      end

    %{mode: mode, thread_id: thread_id, explicit?: explicit_mode != nil}
  end

  defp normalize_mode(mode) when mode in @valid_modes, do: mode
  defp normalize_mode(_), do: "compact"

  defp get_attr(nil, _key), do: nil
  defp get_attr(%{attrs: attrs}, key), do: Map.get(attrs, key)
  defp get_attr(_, _), do: nil

  defp first_present(values) do
    Enum.find(values, fn v -> v not in [nil, ""] end)
  end

  defp first_class(node) do
    node
    |> get_attr("class")
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
  end
end
