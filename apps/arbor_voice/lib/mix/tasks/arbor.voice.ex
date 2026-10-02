defmodule Mix.Tasks.Arbor.Voice do
  use Mix.Task
  alias Arbor.Voice.CLI
  @shortdoc "Test local audio devices and one authenticated voice turn"
  @moduledoc """
  Operates the running local Arbor server; does not start an umbrella runtime.

      mix arbor.voice devices
      mix arbor.voice permission --request
      mix arbor.voice talk agent_ID --loopback --seconds 3
      mix arbor.voice talk agent_ID --seconds 3

  Talk signs a purpose-bound request with `~/.arbor/operator.key` (override with
  `--key-file PATH`). The server keeps the short-lived session proof and audio.
  `--input ID` and `--output ID` select devices; otherwise system defaults apply.
  `--seconds` accepts 1 through 10. A fresh invocation records one bounded clip.
  Exiting the CLI stops lease
  renewal; the server cancels and retains custody until cleanup is confirmed.
  """
  @impl true
  def run(args) do
    case CLI.run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("Voice check failed: #{reason}. Run mix arbor.voice --help for usage.")
    end
  end
end
