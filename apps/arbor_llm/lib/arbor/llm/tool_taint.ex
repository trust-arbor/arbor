defmodule Arbor.LLM.ToolTaint do
  @moduledoc """
  Process-local taint raise and send-capable gate for `Arbor.LLM.ToolLoop`.

  After an untrusted or external tool result enters the loop, later send-capable
  tools (email, HTTP POST, messaging) are refused unless the operator opts out
  with `config :arbor_llm, :strict_taint_send_gate, false`.

  **DEFAULT CHANGE (2026-10-29):** the send gate is on. This is independent of
  the still-dark `config :arbor_security, :egress_gate_enforcing` flag.
  """

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Tool.CallFailure

  @send_capable_exact MapSet.new(~w(
    comms_send_message
    send_email
    send_message
    http_post
  ))

  @external_sources MapSet.new([:mcp, "mcp", :external, "external"])
  @untrusted_levels MapSet.new([:untrusted, :hostile])

  @doc "True when the strict send gate is enabled (default on)."
  @spec strict_taint_send_gate?() :: boolean()
  def strict_taint_send_gate? do
    Application.get_env(:arbor_llm, :strict_taint_send_gate, true) == true
  end

  @doc "True when the tool can send or post content off-host."
  @spec send_capable?(term()) :: boolean()
  def send_capable?(name) when is_binary(name) do
    lowered = String.downcase(name)

    MapSet.member?(@send_capable_exact, lowered) or send_capable_pattern?(lowered)
  end

  def send_capable?(_), do: false

  @doc """
  Refuse a send-capable tool when context is tainted and the gate is on.

  Returns `{:error, %CallFailure{}}` or `nil` when the call may proceed.
  """
  @spec refuse_send(String.t(), Taint.t() | nil) :: {:error, CallFailure.t()} | nil
  def refuse_send(name, taint) when is_binary(name) do
    if send_capable?(name) and tainted_for_send?(taint) and strict_taint_send_gate?() do
      {:error,
       CallFailure.new!(
         outcome: :refused,
         tool: name,
         message:
           "Send-capable tool '#{name}' is blocked because untrusted or external tool " <>
             "output has entered this turn. Request operator approval or opt out with " <>
             "config :arbor_llm, :strict_taint_send_gate, false."
       )}
    end
  end

  def refuse_send(_name, _taint), do: nil

  @doc "True when current taint is untrusted or hostile."
  @spec tainted_for_send?(Taint.t() | nil) :: boolean()
  def tainted_for_send?(%Taint{level: level}), do: MapSet.member?(@untrusted_levels, level)
  def tainted_for_send?(_), do: false

  @doc """
  Raise aggregate taint when a tool result from an untrusted or external source
  enters context. Native trusted results leave taint unchanged.
  """
  @spec raise_from_result(Taint.t() | nil, String.t(), term(), list() | nil) :: Taint.t() | nil
  def raise_from_result(current, name, result, tools) do
    cond do
      external_or_untrusted?(name, result, tools) ->
        join_taint(current, result_taint(name, result))

      true ->
        current
    end
  end

  @doc "Conservative untrusted label for unlabeled `generate_text_with_tools` runs."
  @spec conservative_untrusted(String.t()) :: Taint.t()
  def conservative_untrusted(source) when is_binary(source) do
    %Taint{
      level: :untrusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :unverified,
      source: truncate_source(source),
      chain: []
    }
  end

  defp send_capable_pattern?(name) do
    String.contains?(name, "http_post") or
      String.contains?(name, "httppost") or
      String.contains?(name, "messaging") or
      email_send?(name) or
      named_send?(name)
  end

  defp email_send?(name), do: String.contains?(name, "email")

  defp named_send?(name) do
    String.contains?(name, "send") and
      not String.contains?(name, "sender") and
      not String.contains?(name, "resend")
  end

  defp external_or_untrusted?(name, result, tools) do
    mcp_name?(name) or mcp_source?(name, tools) or untrusted_result?(result)
  end

  defp mcp_name?("mcp." <> rest) when rest != "", do: true
  defp mcp_name?(_), do: false

  defp mcp_source?(name, tools) when is_list(tools) do
    case find_tool(tools, name) do
      %{"source" => source} -> MapSet.member?(@external_sources, source)
      %{source: source} -> MapSet.member?(@external_sources, source)
      _ -> false
    end
  end

  defp mcp_source?(_name, _tools), do: false

  defp find_tool(tools, name) do
    Enum.find(tools, fn
      %{"function" => %{"name" => ^name}} -> true
      %{function: %{name: ^name}} -> true
      %{"name" => ^name} -> true
      %{name: ^name} -> true
      _ -> false
    end)
  end

  defp untrusted_result?({:ok, %{taint: %Taint{level: level}}}),
    do: MapSet.member?(@untrusted_levels, level)

  defp untrusted_result?({:ok, %{taint: %{level: level}}}),
    do: MapSet.member?(@untrusted_levels, level)

  defp untrusted_result?(_), do: false

  defp result_taint(_name, {:ok, %{taint: %Taint{} = taint}}), do: taint

  defp result_taint(name, {:ok, %{taint: taint}}) when is_map(taint) do
    case Taint.canonicalize(taint) do
      {:ok, canon} -> canon
      {:error, _} -> untrusted_tool_taint(name)
    end
  end

  defp result_taint(name, _result), do: untrusted_tool_taint(name)

  defp untrusted_tool_taint(name) do
    %Taint{
      level: :untrusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :plausible,
      source: truncate_source("tool:" <> name),
      chain: []
    }
  end

  defp join_taint(nil, %Taint{} = incoming), do: incoming

  defp join_taint(%Taint{} = current, %Taint{} = incoming) do
    case Taint.join(current, incoming) do
      {:ok, joined} -> joined
      {:error, _} -> Taint.invalid_durable_provenance()
    end
  end

  defp truncate_source(source) when is_binary(source) do
    max = Taint.max_source_bytes()

    if byte_size(source) <= max do
      source
    else
      String.slice(source, 0, max)
    end
  end
end
