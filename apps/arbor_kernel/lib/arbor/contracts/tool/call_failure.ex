defmodule Arbor.Contracts.Tool.CallFailure do
  @moduledoc """
  A tool or action call that produced no result, classified by what is known
  about whether it took effect.

  Surfaces that run a tool on a model's behalf (the LLM tool loop over Arbor
  actions, the gateway's external MCP client) return
  `{:error, %CallFailure{}}` for a failed call, so a caller can decide whether
  repeating it is safe without matching each surface's error terms:

    * `:refused` — declined before anything ran: an unknown tool, a malformed
      call, a binding, signing, authorization, taint or approval gate, or a
      server that rejected the request before running it. Repeating cannot
      duplicate an effect; whether it would succeed depends on why.
    * `:not_sent` — the request never left: the connection was not open, the
      client was gone, or the target could not be reached. Nothing ran.
    * `:failed` — the tool ran and answered with a failure. Its answer says
      what happened.
    * `:unknown` — the tool may have acted and no trustworthy answer came
      back: it raised, threw or exited while running, the call timed out, or
      the connection broke after the request was sent. Check whether it took
      effect before repeating it.

  Only the boundary that knows how far the call got classifies it: the action
  admission boundary (`Arbor.Actions.authorize_and_execute_with_outcome/4`)
  or the MCP connection. A value a tool returns is its answer and never reads
  as `:refused` on its own, and a timeout is always `:unknown`.

  `idempotency` is the tool's declared replay class when the surface knows it
  (`Arbor.Actions.execution_idempotency/2` for actions). `nil` means unknown
  and is treated like `:side_effecting`.
  """

  use TypedStruct

  @outcomes [:refused, :not_sent, :failed, :unknown]
  @idempotency_classes [:idempotent, :idempotent_with_key, :side_effecting, :read_only]
  @repeat_safe_classes [:idempotent, :read_only]

  @type outcome :: :refused | :not_sent | :failed | :unknown
  @type idempotency :: :idempotent | :idempotent_with_key | :side_effecting | :read_only

  typedstruct enforce: true do
    @typedoc "A classified failed tool or action call."

    field(:outcome, outcome())
    field(:message, String.t())
    field(:tool, String.t() | nil, default: nil)
    field(:idempotency, idempotency() | nil, default: nil)
  end

  @doc "Every `t:outcome/0`."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  Build a classified failure.

  Requires `:outcome` (one of `outcomes/0`) and a string `:message`; `:tool`
  and `:idempotency` are optional.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, {:invalid_call_failure, atom()}}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    outcome = Map.get(attrs, :outcome)
    message = Map.get(attrs, :message)
    tool = Map.get(attrs, :tool)
    idempotency = Map.get(attrs, :idempotency)

    cond do
      outcome not in @outcomes ->
        {:error, {:invalid_call_failure, :outcome}}

      not is_binary(message) ->
        {:error, {:invalid_call_failure, :message}}

      not (is_nil(tool) or is_binary(tool)) ->
        {:error, {:invalid_call_failure, :tool}}

      not (is_nil(idempotency) or idempotency in @idempotency_classes) ->
        {:error, {:invalid_call_failure, :idempotency}}

      true ->
        {:ok,
         %__MODULE__{outcome: outcome, message: message, tool: tool, idempotency: idempotency}}
    end
  end

  def new(_attrs), do: {:error, {:invalid_call_failure, :attrs}}

  @doc "Like `new/1`, raising `ArgumentError` on invalid attributes."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, failure} -> failure
      {:error, reason} -> raise ArgumentError, "invalid call failure: #{inspect(reason)}"
    end
  end

  @doc """
  True when the call may have taken effect and repeating it could duplicate
  that effect: the outcome is `:unknown` and the tool is not declared
  `:read_only` or `:idempotent`.

  This is the live counterpart of the durable indeterminate effect that
  `EffectRecoveryCore` refuses to resume. A caller must not repeat such a call
  automatically.
  """
  @spec indeterminate_effect?(t()) :: boolean()
  def indeterminate_effect?(%__MODULE__{outcome: :unknown, idempotency: class}),
    do: class not in @repeat_safe_classes

  def indeterminate_effect?(%__MODULE__{}), do: false

  @doc """
  The failure's message followed by one sentence stating what the outcome
  means for the caller.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{message: message} = failure) do
    case outcome_sentence(failure) do
      nil -> message
      sentence -> message <> "\n" <> sentence
    end
  end

  defp outcome_sentence(%__MODULE__{outcome: :refused}),
    do: "Outcome: refused. The call was not carried out."

  defp outcome_sentence(%__MODULE__{outcome: :not_sent}),
    do: "Outcome: not sent. The call was not carried out."

  defp outcome_sentence(%__MODULE__{outcome: :failed}), do: nil

  defp outcome_sentence(%__MODULE__{outcome: :unknown} = failure) do
    if indeterminate_effect?(failure) do
      "Outcome: unknown. No trustworthy answer came back, so the call may have taken " <>
        "effect. Check whether it did before relying on it or repeating it; it will " <>
        "not be retried automatically."
    else
      "Outcome: unknown. No trustworthy answer came back. The tool is declared safe " <>
        "to repeat."
    end
  end
end
