defmodule Arbor.Voice.Session.ManagedDispatchCore do
  @moduledoc """
  Pure one-dispatch turn admission, success receipt reduction, and presentation
  selection (VP-05D1 / VOICE-10).

  No process, clock, filesystem, network, persistence, Security, Agent, or
  backend effects. Task-intent admission is owned by
  `CodingPlanFactory.admit_intent/1`; this module owns the shared task-id
  grammar and one-dispatch/receipt transitions.
  """

  alias Arbor.Voice.CodingPlanFactory
  alias Arbor.Voice.Session.ToolTaskCore

  @dispatch_name "dispatch_coding_task"
  @max_task_id_bytes 256
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @confirmation_sentence "I've dispatched that coding task; this voice turn is complete."
  @outcome_dispatched "dispatched"

  @type candidate :: %{
          required("provider") => String.t(),
          required("task") => String.t()
        }

  @type receipt :: %{
          required("provider") => String.t(),
          required("task") => String.t(),
          required("task_id") => String.t(),
          required("outcome") => String.t()
        }

  @type t :: %{
          slot: :open | :closed,
          receipt: receipt() | nil
        }

  @doc "Empty turn dispatch state: open slot, no receipt."
  @spec new() :: t()
  def new, do: %{slot: :open, receipt: nil}

  @doc "Exact source-owned confirmation sentence (VOICE-10 / partial VOICE-12)."
  @spec confirmation_sentence() :: String.t()
  def confirmation_sentence, do: @confirmation_sentence

  @doc "Admitted task-intent byte ceiling (delegates to CodingPlanFactory)."
  @spec max_task_intent_bytes() :: pos_integer()
  def max_task_intent_bytes, do: CodingPlanFactory.max_intent_bytes()

  @doc "Authoritative task-id byte ceiling."
  @spec max_task_id_bytes() :: pos_integer()
  def max_task_id_bytes, do: @max_task_id_bytes

  @doc """
  Shared task-id grammar used by FrontDesk success checks, receipt reduction,
  and TranscriptRecorder delegation validation.
  """
  @spec valid_task_id?(term()) :: boolean()
  def valid_task_id?(task_id)
      when is_binary(task_id) and byte_size(task_id) > 0 and
             byte_size(task_id) <= @max_task_id_bytes do
    String.valid?(task_id) and Regex.match?(@task_id_pattern, task_id)
  end

  def valid_task_id?(_), do: false

  @doc """
  Reserve the single per-turn dispatch slot for an exact `dispatch_coding_task`
  call, or leave non-dispatch tools untouched.

  The first matching name closes the slot even when arguments are invalid or a
  later rejection path will not spawn a worker. Failure never reopens the slot.
  """
  @spec reserve_dispatch(t(), %{required(:name) => String.t(), optional(:arguments) => term()}) ::
          {:admit, t(), candidate()}
          | {:reject, t(), String.t()}
          | {:other, t()}
  def reserve_dispatch(%{slot: slot, receipt: receipt} = core, call)
      when is_map(core) and is_map(call) and (slot == :open or slot == :closed) do
    name = Map.get(call, :name)

    cond do
      name != @dispatch_name ->
        {:other, core}

      slot == :closed ->
        # Same established tool-error envelope as ToolTaskCore / FrontDesk normalize.
        {:reject, core, ToolTaskCore.normalize({:error, :tool_error})}

      true ->
        closed = %{slot: :closed, receipt: receipt}

        case admit_task_arg(Map.get(call, :arguments)) do
          {:ok, intent} ->
            candidate = %{
              "provider" => CodingPlanFactory.worker_provider(),
              "task" => intent
            }

            {:admit, closed, candidate}

          :error ->
            # Preserve normal tool-result normalization for invalid first dispatch
            # (ToolTaskCore collapses :invalid_arguments to code "tool_error").
            {:reject, closed, ToolTaskCore.normalize({:error, :invalid_arguments})}
        end
    end
  end

  def reserve_dispatch(core, _call) when is_map(core), do: {:other, core}

  @doc """
  Reduce a generation/call-id/token-fenced normalized tool output into at most
  one receipt for the matching pending candidate.

  Pure only — Session must commit the returned core only after
  `safe_send_tool_result` returns `:ok`.
  """
  @spec maybe_receipt(t(), candidate() | nil, String.t()) :: t()
  def maybe_receipt(%{receipt: receipt} = core, _candidate, _output)
      when not is_nil(receipt),
      do: core

  def maybe_receipt(core, nil, _output) when is_map(core), do: core

  def maybe_receipt(%{slot: :closed, receipt: nil} = core, candidate, output)
      when is_map(candidate) and is_binary(output) do
    case parse_success_envelope(output) do
      {:ok, task_id} ->
        case build_receipt(candidate, task_id) do
          {:ok, receipt} -> %{core | receipt: receipt}
          :error -> core
        end

      :error ->
        core
    end
  end

  def maybe_receipt(core, _candidate, _output) when is_map(core), do: core

  @doc """
  Select raw assistant text for durable/public/spoken presentation.
  """
  @spec select_raw_assistant(t(), String.t()) :: String.t()
  def select_raw_assistant(%{receipt: receipt}, raw_text)
      when not is_nil(receipt) and is_binary(raw_text) do
    @confirmation_sentence
  end

  def select_raw_assistant(_core, raw_text) when is_binary(raw_text), do: raw_text

  @doc "Return the finalized receipt when present."
  @spec receipt(t()) :: receipt() | nil
  def receipt(%{receipt: receipt}), do: receipt

  # -- private ---------------------------------------------------------------

  defp admit_task_arg(%{"task" => task} = args) when map_size(args) == 1 do
    case CodingPlanFactory.admit_intent(task) do
      {:ok, intent} -> {:ok, intent}
      {:error, :invalid_intent} -> :error
    end
  end

  defp admit_task_arg(_), do: :error

  defp parse_success_envelope(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"success" => true, "result" => result} = decoded}
      when is_map(result) and map_size(decoded) == 2 ->
        with true <- map_size(result) == 2,
             {:ok, task_id} <- Map.fetch(result, "task_id"),
             {:ok, status} <- Map.fetch(result, "status"),
             true <- status == @outcome_dispatched,
             true <- valid_task_id?(task_id) do
          {:ok, task_id}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp build_receipt(%{"provider" => provider, "task" => task} = candidate, task_id)
       when map_size(candidate) == 2 and is_binary(provider) and is_binary(task) do
    with true <- provider == CodingPlanFactory.worker_provider(),
         true <- valid_task_id?(task_id),
         {:ok, admitted_task} <- CodingPlanFactory.admit_intent(task) do
      {:ok,
       %{
         "provider" => provider,
         "task" => admitted_task,
         "task_id" => task_id,
         "outcome" => @outcome_dispatched
       }}
    else
      _ -> :error
    end
  end

  defp build_receipt(_candidate, _task_id), do: :error
end
