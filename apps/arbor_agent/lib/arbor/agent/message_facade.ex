defmodule Arbor.Agent.MessageFacade do
  @moduledoc false

  # Library-local implementation of authorized live-agent messaging.
  # Public entry is Arbor.Agent.send_message/4, which always passes fixed
  # Arbor.Security.authorize/3 and Arbor.Agent.Manager.chat/3 collaborators.
  # deliver/6 accepts funs only so unit tests can inject authorization and
  # delivery faults without ambient Process/Application hijacking.

  alias Arbor.Contracts.Session.UserMessage

  @default_timeout_ms 30_000
  @max_timeout_ms 30_000
  @max_id_bytes 256
  @max_content_bytes 32_768
  @max_engagement_id_bytes 256
  # Whole-string positive allowlist for ids interpolated into
  # arbor://chat/agent/<target>. Equivalent to
  # \A(?:agent|human)_[A-Za-z0-9_-]+\z plus the 256-byte bound.
  @principal_id_re ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/

  @type error_reason ::
          :invalid_opts
          | :invalid_timeout
          | :invalid_caller_id
          | :invalid_agent_id
          | :invalid_message
          | :invalid_content
          | :invalid_sender
          | :invalid_engagement_id
          | :unauthorized
          | :delivery_failed

  @doc false
  @spec deliver(
          String.t(),
          String.t(),
          UserMessage.t(),
          keyword(),
          (String.t(), String.t(), atom() -> term()),
          (term(), String.t(), keyword() -> term())
        ) :: {:ok, String.t()} | {:error, error_reason()}
  def deliver(caller_id, target_agent_id, message, opts, authorize_fun, chat_fun)
      when is_function(authorize_fun, 3) and is_function(chat_fun, 3) do
    with {:ok, timeout_ms} <- validate_opts(opts),
         :ok <- validate_principal_id(caller_id, :invalid_caller_id),
         :ok <- validate_principal_id(target_agent_id, :invalid_agent_id),
         :ok <- validate_message(message, caller_id),
         :ok <- authorize_chat(authorize_fun, caller_id, target_agent_id) do
      deliver_chat(chat_fun, message, caller_id, target_agent_id, timeout_ms)
    end
  end

  defp validate_opts(opts) when not is_list(opts), do: {:error, :invalid_opts}

  defp validate_opts(opts) do
    # Keyword.keyword?/1 can raise on improper lists; fail closed.
    try do
      cond do
        not Keyword.keyword?(opts) ->
          {:error, :invalid_opts}

        has_duplicate_keys?(opts) ->
          {:error, :invalid_opts}

        true ->
          case Enum.reject(Keyword.keys(opts), &(&1 == :timeout)) do
            [] -> validate_timeout(Keyword.get(opts, :timeout, @default_timeout_ms))
            _unknown -> {:error, :invalid_opts}
          end
      end
    rescue
      _ -> {:error, :invalid_opts}
    catch
      :exit, _ -> {:error, :invalid_opts}
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms,
       do: {:ok, timeout}

  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp validate_principal_id(id, error)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_id_bytes do
    if String.valid?(id) and Regex.match?(@principal_id_re, id) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_principal_id(_id, error), do: {:error, error}

  defp validate_message(%UserMessage{} = message, caller_id) do
    with :ok <- validate_content(message.content),
         :ok <- validate_sender(message.sender_id, caller_id),
         :ok <- validate_engagement_id(message.engagement_id) do
      :ok
    end
  end

  defp validate_message(_message, _caller_id), do: {:error, :invalid_message}

  defp validate_content(content)
       when is_binary(content) and byte_size(content) > 0 and
              byte_size(content) <= @max_content_bytes do
    cond do
      not String.valid?(content) -> {:error, :invalid_content}
      String.trim(content) == "" -> {:error, :invalid_content}
      true -> :ok
    end
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_sender(sender_id, caller_id) when sender_id === caller_id, do: :ok
  defp validate_sender(_sender_id, _caller_id), do: {:error, :invalid_sender}

  defp validate_engagement_id(engagement_id)
       when is_binary(engagement_id) and byte_size(engagement_id) > 0 and
              byte_size(engagement_id) <= @max_engagement_id_bytes do
    cond do
      not String.valid?(engagement_id) -> {:error, :invalid_engagement_id}
      String.contains?(engagement_id, <<0>>) -> {:error, :invalid_engagement_id}
      String.trim(engagement_id) == "" -> {:error, :invalid_engagement_id}
      true -> :ok
    end
  end

  defp validate_engagement_id(_), do: {:error, :invalid_engagement_id}

  defp authorize_chat(authorize_fun, caller_id, target_agent_id) do
    resource = "arbor://chat/agent/" <> target_agent_id

    case authorize_fun.(caller_id, resource, :chat) do
      {:ok, :authorized} -> :ok
      {:ok, :pending_approval, _proposal_id} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :unauthorized}
      _other -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :throw, _ -> {:error, :unauthorized}
    :exit, _ -> {:error, :unauthorized}
  end

  defp deliver_chat(chat_fun, message, caller_id, target_agent_id, timeout_ms) do
    case chat_fun.(message, caller_id, agent_id: target_agent_id, timeout: timeout_ms) do
      {:ok, reply} when is_binary(reply) -> {:ok, reply}
      {:ok, _non_binary} -> {:error, :delivery_failed}
      {:error, _reason} -> {:error, :delivery_failed}
      _other -> {:error, :delivery_failed}
    end
  rescue
    _ -> {:error, :delivery_failed}
  catch
    :throw, _ -> {:error, :delivery_failed}
    :exit, _ -> {:error, :delivery_failed}
  end
end
