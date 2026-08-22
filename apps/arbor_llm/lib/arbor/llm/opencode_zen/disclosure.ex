defmodule Arbor.LLM.OpenCodeZen.Disclosure do
  @moduledoc false

  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  @ack_filename "opencode_zen_disclosure.json"

  @doc "The user-facing disclosure text."
  @spec text() :: String.t()
  def text, do: AdmissionCore.disclosure_text()

  @doc "Whether a persisted acknowledgement exists."
  @spec acknowledged?() :: boolean()
  def acknowledged? do
    match?(:ok, AdmissionCore.request_permitted?(read_ack()))
  end

  @doc """
  Fail closed unless the user has acknowledged the disclosure.

  Does not prompt and does not auto-accept. Mix/CLI entry points call
  `prompt/0` first; the adapter calls this immediately before dispatch.
  """
  @spec ensure() :: :ok | {:error, :disclosure_not_acknowledged}
  def ensure, do: AdmissionCore.request_permitted?(read_ack())

  @doc """
  Persist an active acknowledgement. Callers must have shown the text
  and received an explicit yes — this function does not print or prompt.
  """
  @spec persist(String.t()) :: :ok | {:error, term()}
  def persist(at) when is_binary(at) do
    path = acknowledgement_path()
    :ok = File.mkdir_p(Path.dirname(path))

    payload = JSON.encode!(%{"acknowledged" => true, "at" => at, "version" => 1})
    File.write(path, payload)
  end

  @doc """
  Show the disclosure and require an active yes. Persists on yes.
  """
  @spec prompt(keyword()) :: :ok | {:error, :disclosure_not_acknowledged}
  def prompt(opts \\ []) do
    if acknowledged?() do
      :ok
    else
      do_prompt(opts)
    end
  end

  @spec acknowledgement_path() :: String.t()
  def acknowledgement_path do
    case Application.get_env(:arbor_llm, :opencode_zen_acknowledgement_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Path.join([System.user_home(), ".arbor", @ack_filename])
    end
  end

  defp do_prompt(opts) do
    yes? = Keyword.get(opts, :yes_fn, &default_yes?/0)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.to_iso8601())

    Mix.shell().info("")
    Mix.shell().info(text())

    if yes?.() do
      case persist(now) do
        :ok -> :ok
        {:error, _reason} -> {:error, :disclosure_not_acknowledged}
      end
    else
      {:error, :disclosure_not_acknowledged}
    end
  end

  defp default_yes? do
    Mix.shell().yes?("Do you acknowledge this and want to continue?")
  end

  defp read_ack do
    case File.read(acknowledgement_path()) do
      {:ok, contents} ->
        case JSON.decode(contents) do
          {:ok, payload} -> payload
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
