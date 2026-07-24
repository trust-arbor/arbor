defmodule Arbor.Consensus.Evaluator.DeterministicRequest do
  @moduledoc """
  Closed lookup request for authorization-bound deterministic evidence.

  It intentionally contains no path, command, argv, environment, sandbox, or
  caller-supplied test selection.
  """

  use TypedStruct

  @version 1
  @perspectives [
    :mix_test,
    :mix_credo,
    :mix_compile,
    :mix_format_check,
    :mix_dialyzer
  ]
  @max_proposal_id_bytes 256
  @max_timeout_ms 1_200_000

  typedstruct enforce: true do
    field(:version, pos_integer())
    field(:proposal_id, String.t())
    field(:perspective, atom())
    field(:timeout_ms, pos_integer())
  end

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_deterministic_request}
  def new(%{proposal_id: proposal_id, perspective: perspective, timeout_ms: timeout_ms} = attrs)
      when map_size(attrs) == 3 and not is_struct(attrs) do
    if valid_proposal_id?(proposal_id) and perspective in @perspectives and
         is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms do
      {:ok,
       %__MODULE__{
         version: @version,
         proposal_id: proposal_id,
         perspective: perspective,
         timeout_ms: timeout_ms
       }}
    else
      {:error, :invalid_deterministic_request}
    end
  end

  def new(_attrs), do: {:error, :invalid_deterministic_request}

  defp valid_proposal_id?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_proposal_id_bytes and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end
end
