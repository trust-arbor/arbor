defmodule Arbor.Common.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_log_redaction_filter()

    optional_children =
      if Arbor.Common.Config.start_children?() do
        [
          # pg scope for cross-node registry discovery
          %{
            id: :arbor_registry_pg,
            start: {:pg, :start_link, [:arbor_registry]}
          },
          Arbor.Common.NodeRegistry,
          Arbor.Common.ReadableRegistry,
          Arbor.Common.WriteableRegistry,
          Arbor.Common.ComputeRegistry,
          Arbor.Common.PipelineResolver,
          Arbor.Common.ActionRegistry,
          # No explicit dirs: SkillLibrary uses its default search path (personal
          # ~/.agents/skills + ~/.arbor/library/skills, project .agents/skills, bundled
          # priv/library/skills; personal overrides bundled). See default_skill_dirs/0.
          Arbor.Common.SkillLibrary,
          Arbor.Common.AgentTelemetry.Store,
          {Arbor.Common.CapabilityIndex,
           providers: [
             Arbor.Common.CapabilityProviders.ActionProvider,
             Arbor.Common.CapabilityProviders.SkillProvider
           ]}
        ]
      else
        []
      end

    # OAuth's public HTTP boundary remains usable in isolated app tests where
    # the registry/stateful Common children are deliberately disabled.
    children = [Arbor.Common.OAuth.HttpClient.Pool | optional_children]

    opts = [strategy: :one_for_one, name: Arbor.Common.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # M7: Install API key/token redaction as a primary Logger filter so every
  # handler sees redacted events, not only :default. Append after Elixir's
  # translator so crash reports still carry :elixir_translation. Must be done
  # at runtime since config.exs can't hold function references.
  defp install_log_redaction_filter do
    filter = {:api_key_redaction, {&Arbor.Common.LogRedactor.filter/2, :log}}
    %{filters: filters} = :logger.get_primary_config()

    if Enum.any?(filters, &match?({:api_key_redaction, _}, &1)) do
      :ok
    else
      case :logger.set_primary_config(:filters, filters ++ [filter]) do
        :ok -> :ok
        {:error, reason} -> raise "failed to install log redaction filter: #{inspect(reason)}"
      end
    end
  end
end
