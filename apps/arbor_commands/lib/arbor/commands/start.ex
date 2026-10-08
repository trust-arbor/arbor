defmodule Arbor.Commands.Start do
  @moduledoc """
  Request a new agent from a template.

  Mirrors `mix arbor.agent start <template>` for the in-chat surface, but it
  does not start anything itself. Creating and starting an agent mutates
  security state, which needs the authenticated human's lifecycle authority
  (decision 2026-10-08 D3). That proof lives with the ingress that
  authenticated the human (a browser session, a verified signed request), not
  in a command `Context`, and it must not be moved into an agent's Session.
  So `/start` only validates its arguments and returns the
  `{:start_agent, template, opts}` action. An ingress performs it through the
  `Arbor.Agent` lifecycle facade with its own proof or, when it holds no human
  proof, refuses it with a clear message. It never performs it with ambient
  authority.

  ## Usage

      /start <template>                         # spawn with template defaults
      /start <template> name=Foo                # override display name
      /start <template> model=claude-opus-4-6   # override model
      /start <template> runtime=acp             # override runtime
      /start <template> model=X runtime=acp     # combine

  The action's `opts` carry only the overrides given: `name:`, `model:` and
  `runtime:`.
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @valid_runtimes [:arbor, :acp]
  @usage "Usage: /start <template> [name=...] [model=...] [runtime=arbor|acp]"

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
  def execute("", %Context{}), do: {:ok, Result.error(@usage)}

  def execute(args, %Context{}) do
    case parse_args(args) do
      {:ok, template, opts} ->
        display_name = Keyword.get(opts, :name, template)

        {:ok,
         Result.action(
           "Requested a new agent from template #{template} as #{display_name}.",
           {:start_agent, template, opts}
         )}

      {:error, {:unknown_runtime, value}} ->
        {:ok,
         Result.error(
           "Unknown runtime '#{value}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
         )}

      {:error, :missing_template} ->
        {:ok, Result.error(@usage)}
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
