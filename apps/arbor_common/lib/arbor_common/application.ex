defmodule Arbor.Common.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_log_redaction_filter()

    children =
      if Application.get_env(:arbor_common, :start_children, true) do
        [
          Arbor.Common.ReadableRegistry,
          Arbor.Common.WriteableRegistry,
          Arbor.Common.ComputeRegistry,
          Arbor.Common.PipelineResolver,
          Arbor.Common.ActionRegistry
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Common.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # M7: Install API key/token redaction filter on the default Logger handler.
  # Must be done at runtime since config.exs can't hold function references.
  defp install_log_redaction_filter do
    :logger.add_handler_filter(
      :default,
      :api_key_redaction,
      {&Arbor.Common.LogRedactor.filter/2, :log}
    )
  rescue
    _ -> :ok
  end
end
