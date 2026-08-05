defmodule Arbor.Memory.ArchiveCursorSigner do
  @moduledoc false

  use GenServer

  @name __MODULE__
  @prefix "arc1"
  @mac_bytes 32
  @max_payload_bytes 2_048
  @max_token_bytes 4_096

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @spec max_token_bytes() :: pos_integer()
  def max_token_bytes, do: @max_token_bytes

  @spec sign(binary(), binary()) :: {:ok, String.t()} | {:error, :cursor_signer_unavailable}
  def sign(payload, target_context)
      when is_binary(payload) and byte_size(payload) <= @max_payload_bytes and
             is_binary(target_context) do
    safe_call({:sign, payload, target_context})
  end

  def sign(_payload, _target_context), do: {:error, :cursor_signer_unavailable}

  @spec verify(String.t(), binary()) ::
          {:ok, binary()} | {:error, :invalid_archive_cursor | :cursor_signer_unavailable}
  def verify(token, target_context)
      when is_binary(token) and byte_size(token) <= @max_token_bytes and
             is_binary(target_context) do
    safe_call({:verify, token, target_context})
  end

  def verify(_token, _target_context), do: {:error, :invalid_archive_cursor}

  @impl GenServer
  def init(:ok), do: {:ok, :crypto.strong_rand_bytes(@mac_bytes)}

  @impl GenServer
  def handle_call({:sign, payload, target_context}, _from, key) do
    mac = authentication_code(key, payload, target_context)

    token =
      [
        @prefix,
        Base.url_encode64(payload, padding: false),
        Base.url_encode64(mac, padding: false)
      ]
      |> Enum.join(".")

    {:reply, {:ok, token}, key}
  end

  def handle_call({:verify, token, target_context}, _from, key) do
    result =
      with [@prefix, encoded_payload, encoded_mac] <- String.split(token, ".", parts: 3),
           {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
           true <- byte_size(payload) <= @max_payload_bytes,
           {:ok, mac} <- Base.url_decode64(encoded_mac, padding: false),
           true <- byte_size(mac) == @mac_bytes,
           expected <- authentication_code(key, payload, target_context),
           true <- :crypto.hash_equals(expected, mac) do
        {:ok, payload}
      else
        _invalid -> {:error, :invalid_archive_cursor}
      end

    {:reply, result, key}
  end

  defp authentication_code(key, payload, target_context) do
    framed = <<byte_size(payload)::unsigned-big-32, payload::binary, target_context::binary>>
    :crypto.mac(:hmac, :sha256, key, framed)
  end

  defp safe_call(request) do
    GenServer.call(@name, request)
  rescue
    _error -> {:error, :cursor_signer_unavailable}
  catch
    :exit, _reason -> {:error, :cursor_signer_unavailable}
  end
end
