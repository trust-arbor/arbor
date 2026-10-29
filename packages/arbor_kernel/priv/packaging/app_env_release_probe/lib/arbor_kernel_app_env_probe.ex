# Probe-only fixture; not a production release.
defmodule ArborKernelAppEnvProbe do
  @spec run() :: :ok
  def run do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_app_env_probe)

    payload = %{
      "common" => %{
        "start_children" => Arbor.Common.Config.start_children?(),
        "skill_embedding_module" => encode_term(Arbor.Common.Config.skill_embedding_module()),
        "skill_dirs" => encode_term(Arbor.Common.Config.skill_dirs()),
        "skill_embedding_dimensions" => Arbor.Common.Config.skill_embedding_dimensions(),
        "tool_catalog_enabled" => Arbor.Common.Config.tool_catalog_enabled?()
      },
      "signals" => %{
        "start_children" => Arbor.Signals.Config.start_children?(),
        "durable_sink_module" => encode_term(Arbor.Signals.Config.durable_sink_module()),
        "authorizer" => encode_term(Arbor.Signals.Config.authorizer()),
        "relay_enabled" => Arbor.Signals.Config.relay_enabled?()
      },
      "monitor" => %{
        "start_children" => Arbor.Monitor.Config.start_children?(),
        "channel_bridge_module" => encode_term(Arbor.Monitor.Config.channel_bridge_module()),
        "polling_interval" => Arbor.Monitor.Config.polling_interval(),
        "signal_emission_enabled" => Arbor.Monitor.Config.signal_emission_enabled?()
      },
      "started" => started_apps()
    }

    IO.puts(Jason.encode!(payload))
  end

  defp started_apps do
    Application.started_applications()
    |> Enum.map(fn {name, _desc, _vsn} -> Atom.to_string(name) end)
    |> Enum.sort()
  end

  defp encode_term(nil), do: nil
  defp encode_term(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_term(value) when is_binary(value), do: value
  defp encode_term(value) when is_number(value) or is_boolean(value), do: value
  defp encode_term(value), do: inspect(value)
end
