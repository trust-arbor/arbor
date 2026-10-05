defmodule ConversationKit.Arbor.ComposerCommands do
  @moduledoc false
  @max_bytes 32_768
  @local %{
    "agents" => :agents,
    "help" => :help,
    "quit" => :quit,
    "retry" => :retry,
    "refresh" => :refresh,
    "disconnect" => :disconnect,
    "reconnect" => :reconnect,
    "older" => :older,
    "newer" => :newer,
    "latest" => :latest,
    "work" => :work,
    "more-work" => :more_activity,
    "latest-work" => :latest_activity,
    "notices" => :notices,
    "older-notices" => :older_notices,
    "latest-notices" => :latest_notices
  }
  @management ~w(agents agent attach alias connect new start stop delete destroy)

  def classify(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    if String.valid?(text) do
      case String.trim_leading(text) do
        "/" <> command -> classify_slash(command)
        _ -> {:message, text}
      end
    else
      {:error, :invalid_input}
    end
  end

  def classify(_), do: {:error, :invalid_input}

  defp classify_slash(command) do
    case String.split(String.trim_trailing(command), ~r/\s/u, parts: 2, trim: false) do
      [name] ->
        case Map.fetch(@local, name) do
          {:ok, action} -> {:local, action}
          :error -> unavailable(name)
        end

      ["attach", arguments] ->
        if byte_size(arguments) in 1..256 and String.trim(arguments) != "" and
             not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, command),
           do: {:local, {:attach, arguments}},
           else: {:unavailable, :management}

      [name, _arguments] ->
        unavailable(name)

      [] ->
        {:unavailable, :runtime_command}
    end
  end

  defp unavailable(name) when name in @management, do: {:unavailable, :management}
  defp unavailable(_), do: {:unavailable, :runtime_command}
end
