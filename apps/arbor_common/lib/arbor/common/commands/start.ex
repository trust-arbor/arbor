defmodule Arbor.Common.Commands.Start do
  @moduledoc """
  Spawn a new agent from a template.

  Mirrors `mix arbor.agent start <template>` for the in-chat surface.
  Returns the `{:start_agent, template, opts}` action — the entry point
  (e.g. ChatLive) executes the actual `Arbor.Agent.Manager.start_or_resume/3`
  call.

  ## Usage

      /start <template>                         # spawn with template defaults
      /start <template> name=Foo                # override display name
      /start <template> model=claude-opus-4-6   # override model
      /start <template> runtime=acp             # override runtime
      /start <template> model=X runtime=acp     # combine

  ## Why slash-command rather than UI

  Per `.arbor/decisions/2026-06-04-slash-commands-for-runtime-config.md`,
  user-facing config goes through slash commands. The previous ChatLive
  "Start Agent" dropdown bundled model selection with agent creation
  and conflated several axes. `/start <template>` keeps the start surface
  composable — adding skills, fallback chain pins, or other axes is
  another keyword, not another dropdown.
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @valid_runtimes [:arbor, :acp]

  @impl true
  def name, do: "start"

  @impl true
  def description, do: "Start a new agent from a template"

  @impl true
  def usage,
    do: "/start <template> [name=...] [model=...] [runtime=arbor|acp]"

  @impl true
  def available?(%Context{}), do: true

  @impl true
  def execute("", %Context{}) do
    {:ok, Result.error("Usage: /start <template> [name=...] [model=...] [runtime=arbor|acp]")}
  end

  def execute(args, %Context{}) do
    case parse_args(args) do
      {:ok, template, opts} ->
        apply_start(template, opts)

      {:error, {:unknown_runtime, value}} ->
        {:ok,
         Result.error(
           "Unknown runtime '#{value}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
         )}

      {:error, :missing_template} ->
        {:ok, Result.error("Usage: /start <template> [name=...] [model=...] [runtime=arbor|acp]")}
    end
  end

  # Side-effecting dispatch — spawns the agent via
  # Arbor.Agent.Manager.start_or_resume/3 mirroring `mix arbor.agent
  # start <template>`. Returns an :agent_started effect carrying the
  # agent_id, pid, and metadata that interfaces use for their own
  # follow-up (ChatLive reconnects the socket; Discord binds the
  # channel and subscribes to signals).
  #
  # Runtime indirection because arbor_common is at Level 0.5 and can't
  # compile-time-depend on arbor_agent (Level 2).
  defp apply_start(template, opts) do
    manager_mod = Module.concat([:Arbor, :Agent, :Manager])
    api_agent_mod = Module.concat([:Arbor, :Agent, :APIAgent])

    cond do
      not Code.ensure_loaded?(manager_mod) ->
        {:ok, Result.error("Cannot start agent: Manager module not loaded.")}

      not Code.ensure_loaded?(api_agent_mod) ->
        {:ok, Result.error("Cannot start agent: APIAgent module not loaded.")}

      true ->
        run_start(manager_mod, api_agent_mod, template, opts)
    end
  end

  defp run_start(manager_mod, api_agent_mod, template, opts) do
    display_name = Keyword.get(opts, :name, template)
    model_config = build_model_config(api_agent_mod, opts)
    start_opts = [template: template, model_config: model_config]

    case safe_call(manager_mod, :start_or_resume, [api_agent_mod, display_name, start_opts]) do
      {:ok, agent_id, pid} ->
        text =
          "Started agent from template #{template} as #{display_name} (#{agent_id})."

        effects = [
          agent_started: %{
            agent_id: agent_id,
            pid: pid,
            metadata: %{template: template, model_config: model_config}
          }
        ]

        effects =
          case Keyword.get(opts, :runtime) do
            nil -> effects
            runtime -> effects ++ [runtime_changed: runtime]
          end

        {:ok, Result.ok(text, effects)}

      {:error, reason} ->
        {:ok, Result.error("/start failed: #{inspect(reason)}")}
    end
  end

  # Mirrors the shape used by mix arbor.agent start <template>. Falls
  # back to LLMDefaults when /start doesn't pin model/provider.
  defp build_model_config(api_agent_mod, opts) do
    defaults_mod = Module.concat([:Arbor, :Agent, :LLMDefaults])

    model_id =
      Keyword.get(opts, :model) || safe_default(defaults_mod, :default_model, "claude-sonnet-4-6")

    provider =
      Keyword.get(opts, :provider) ||
        safe_default(defaults_mod, :default_provider, :anthropic)

    %{
      id: model_id,
      provider: provider,
      backend: :api,
      module: api_agent_mod,
      start_opts: []
    }
  end

  defp safe_default(mod, fun, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      fallback
    end
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp safe_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp parse_args(args) do
    args = String.trim(args)
    tokens = String.split(args, ~r/\s+/, trim: true)

    {kv_tokens, positional} =
      Enum.split_with(tokens, fn t -> String.contains?(t, "=") end)

    with {:ok, opts} <- parse_kvs(kv_tokens, []) do
      case positional do
        [template | _rest] -> {:ok, template, opts}
        [] -> {:error, :missing_template}
      end
    end
  end

  defp parse_kvs([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_kvs(["name=" <> value | rest], acc) do
    parse_kvs(rest, [{:name, String.trim(value)} | acc])
  end

  defp parse_kvs(["model=" <> value | rest], acc) do
    parse_kvs(rest, [{:model, String.trim(value)} | acc])
  end

  defp parse_kvs(["runtime=" <> value | rest], acc) do
    value = String.trim(value)

    case runtime_atom(value) do
      {:ok, runtime} -> parse_kvs(rest, [{:runtime, runtime} | acc])
      :error -> {:error, {:unknown_runtime, value}}
    end
  end

  defp parse_kvs([_ignored | rest], acc) do
    # Unknown kwargs silently skip — future axes (skills=..., chain=...)
    # can land without breaking parse.
    parse_kvs(rest, acc)
  end

  defp runtime_atom("arbor"), do: {:ok, :arbor}
  defp runtime_atom("acp"), do: {:ok, :acp}
  defp runtime_atom(_), do: :error
end
