defmodule Arbor.Security.RoutineOwnerRequest do
  @moduledoc false

  # Owner-signed scheduler requests are a closed wire format, not capability
  # URIs. The signing authority may sign this shape and nothing arbitrary.
  # Bytes must stay aligned with Arbor.Scheduler.Cores.RoutineCore.
  @domain "arbor.scheduler.owner-request.v1"
  @operations ["enqueue", "list", "cancel"]
  # Eight parents, each carrying a resource URI up to 4_096 bytes, plus digests.
  @max_bytes 65_536

  @spec payload(String.t(), binary()) :: {:ok, binary()} | {:error, :invalid_routine_request}
  def payload(operation, body)
      when operation in @operations and is_binary(body) and body != "" do
    encoded = @domain <> <<0>> <> operation <> <<0>> <> body

    if valid?(encoded), do: {:ok, encoded}, else: {:error, :invalid_routine_request}
  end

  def payload(_operation, _body), do: {:error, :invalid_routine_request}

  @spec valid?(term()) :: boolean()
  def valid?(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :binary.split(payload, <<0>>, [:global]) do
      [@domain, operation, body] when operation in @operations ->
        body != "" and String.valid?(body)

      _ ->
        false
    end
  end

  def valid?(_payload), do: false
end
