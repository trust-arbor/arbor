defmodule Arbor.Voice.Session.ToolTaskCore do
  @moduledoc """
  Pure normalization and fence decisions for voice tool outcomes (VP-04E3).

  No pids, clocks, timers, or backend I/O.
  """

  alias Arbor.Voice.Session.JsonTerm
  alias Arbor.Voice.Session.TurnCore

  @max_output_bytes JsonTerm.max_encoded_bytes()

  @doc "Encoded output byte ceiling."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc "Max nesting depth for successful router result values."
  @spec max_result_depth() :: pos_integer()
  def max_result_depth, do: JsonTerm.max_depth()

  @doc "Max nodes for successful router result values."
  @spec max_result_nodes() :: pos_integer()
  def max_result_nodes, do: JsonTerm.max_nodes()

  @doc "Max concurrent outstanding tool calls per Session."
  @spec max_outstanding() :: pos_integer()
  def max_outstanding, do: 8

  @doc """
  Normalize a router/worker outcome into a deterministic JSON object string.
  """
  @spec normalize(term()) :: String.t()
  def normalize(:tool_timeout), do: code_json("tool_timeout")
  def normalize(:tool_failed), do: code_json("tool_failed")
  def normalize(:tool_capacity_exceeded), do: code_json("tool_capacity_exceeded")
  def normalize(:router_unavailable), do: code_json("router_unavailable")
  def normalize(:tool_cancelled), do: code_json("tool_cancelled")

  def normalize({:error, :no_tools_installed}), do: TurnCore.no_tools_installed_output()
  def normalize({:error, :unknown_tool}), do: code_json("unknown_tool")
  def normalize({:error, reason}) when is_atom(reason), do: code_json("tool_error")

  def normalize({:ok, result}) do
    case JsonTerm.validate(result) do
      :ok -> encode_or_invalid(%{"success" => true, "result" => result})
      :error -> code_json("invalid_output")
    end
  end

  def normalize(_other), do: code_json("invalid_return")

  @doc """
  Authorize a proposed tool outcome against Session pending authority.
  """
  @spec authorize(map() | nil, non_neg_integer(), String.t(), reference(), non_neg_integer()) ::
          :settle | :ignore
  def authorize(pending_entry, generation, call_id, token, live_generation)
      when is_binary(call_id) and is_reference(token) and is_integer(generation) and
             is_integer(live_generation) do
    cond do
      generation != live_generation -> :ignore
      not is_map(pending_entry) -> :ignore
      Map.get(pending_entry, :token) != token -> :ignore
      true -> :settle
    end
  end

  def authorize(_pending_entry, _generation, _call_id, _token, _live_generation), do: :ignore

  @doc "Authorize an owner DOWN against the stored monitor ref."
  @spec authorize_down(map() | nil, reference(), non_neg_integer(), non_neg_integer()) ::
          :settle | :ignore
  def authorize_down(pending_entry, mon_ref, generation, live_generation)
      when is_reference(mon_ref) and is_integer(generation) and is_integer(live_generation) do
    cond do
      generation != live_generation -> :ignore
      not is_map(pending_entry) -> :ignore
      Map.get(pending_entry, :owner_mon) != mon_ref -> :ignore
      true -> :settle
    end
  end

  def authorize_down(_pending_entry, _mon_ref, _generation, _live_generation), do: :ignore

  defp code_json(code) when is_binary(code) do
    Jason.encode!(%{"code" => code})
  end

  defp encode_or_invalid(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, encoded} when is_binary(encoded) and byte_size(encoded) <= @max_output_bytes ->
        if String.valid?(encoded), do: encoded, else: code_json("invalid_output")

      _ ->
        code_json("invalid_output")
    end
  end
end
