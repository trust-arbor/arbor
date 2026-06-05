defmodule Arbor.Commands.Start do
  @moduledoc """
  Spawn a new agent from a template.

  Mirrors `mix arbor.agent start <template>` for the in-chat surface.
  On success emits an `:agent_started` effect carrying the new agent's
  `agent_id`, `pid`, and `metadata` — interface modules (ChatLive,
  Discord, etc.) use this to bind their conversation to the new agent.

  ## Usage

      /start <template>                         # spawn with template defaults
      /start <template> name=Foo                # override display name
      /start <template> model=claude-opus-4-6   # override model
      /start <template> runtime=acp             # override runtime
      /start <template> model=X runtime=acp     # combine

  ## Why this lives in arbor_commands

  Performs side effects via `Arbor.Agent.Manager.start_or_resume/3`.
  arbor_commands depends on arbor_agent directly so the call is
  compile-time-checked. arbor_common can't depend on arbor_agent
  (Level 0.5 → Level 2 violates the hierarchy).
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Agent.{APIAgent, LLMDefaults, Manager}
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
        run_start(template, opts)

      {:error, {:unknown_runtime, value}} ->
        {:ok,
         Result.error(
           "Unknown runtime '#{value}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
         )}

      {:error, :missing_template} ->
        {:ok, Result.error("Usage: /start <template> [name=...] [model=...] [runtime=arbor|acp]")}
    end
  end

  defp run_start(template, opts) do
    display_name = Keyword.get(opts, :name, template)
    model_config = build_model_config(opts)
    start_opts = [template: template, model_config: model_config]

    case safe_call(fn -> Manager.start_or_resume(APIAgent, display_name, start_opts) end) do
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

  # Mirrors `mix arbor.agent start <template>`. Falls back to
  # `Arbor.Agent.LLMDefaults` when /start doesn't pin model/provider.
  defp build_model_config(opts) do
    model_id =
      Keyword.get(opts, :model) || safe_default(&LLMDefaults.default_model/0, "claude-sonnet-4-6")

    provider =
      Keyword.get(opts, :provider) || safe_default(&LLMDefaults.default_provider/0, :anthropic)

    %{
      id: model_id,
      provider: provider,
      runtime: :arbor,
      module: APIAgent,
      start_opts: []
    }
  end

  defp safe_default(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp safe_call(fun) do
    fun.()
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
    case runtime_atom(String.trim(value)) do
      {:ok, runtime} -> parse_kvs(rest, [{:runtime, runtime} | acc])
      :error -> {:error, {:unknown_runtime, value}}
    end
  end

  defp parse_kvs([_ignored | rest], acc) do
    # Unknown kwargs silently skip.
    parse_kvs(rest, acc)
  end

  defp runtime_atom("arbor"), do: {:ok, :arbor}
  defp runtime_atom("acp"), do: {:ok, :acp}
  defp runtime_atom(_), do: :error
end
