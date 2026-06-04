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
        label = build_label(template, opts)
        {:ok, Result.action(label, {:start_agent, template, opts})}

      {:error, {:unknown_runtime, value}} ->
        {:ok,
         Result.error(
           "Unknown runtime '#{value}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
         )}
    end
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

  defp build_label(template, opts) do
    suffix =
      opts
      |> Enum.map_join(", ", fn
        {:name, v} -> "name=#{v}"
        {:model, v} -> "model=#{v}"
        {:runtime, v} -> "runtime=#{v}"
        {k, v} -> "#{k}=#{inspect(v)}"
      end)

    case suffix do
      "" -> "Starting agent from template: #{template}"
      _ -> "Starting agent from template: #{template} (#{suffix})"
    end
  end
end
