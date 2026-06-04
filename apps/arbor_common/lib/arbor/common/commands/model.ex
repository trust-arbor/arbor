defmodule Arbor.Common.Commands.Model do
  @moduledoc """
  Show or switch the current LLM model.

  ## Usage

      /model                              # show current model
      /model list                         # show available models
      /model claude-opus-4-6              # switch model
      /model claude-opus-4-6 runtime=acp  # switch model + runtime in one
      /model runtime=acp                  # rejected — use /runtime for that

  When `runtime=<atom>` is the only argument given, the command points
  the user at `/runtime` since the parse otherwise treats `runtime=acp`
  as the model spec.
  """
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @valid_runtimes [:arbor, :acp]

  @impl true
  def name, do: "model"

  @impl true
  def description, do: "Show or switch LLM model"

  @impl true
  def usage, do: "/model [provider/model-name] [runtime=arbor|acp]"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute("", %Context{} = ctx) do
    model = ctx.model || "not set"
    provider = ctx.provider || "unknown"
    {:ok, Result.ok("Current model: #{model} (#{provider})")}
  end

  def execute("list", %Context{}) do
    # Listing available models requires querying providers (network I/O),
    # which is the caller's job. The command itself stays pure — return
    # informational text. A future :list_models action could push this
    # back to the caller for richer output.
    {:ok,
     Result.ok(
       "Model listing isn't yet wired to a backend. " <>
         "Use the provider's API or check the model registry directly."
     )}
  end

  def execute(args, %Context{} = ctx) do
    case Context.has_agent?(ctx) do
      false ->
        {:ok, Result.error("Cannot switch model: no current agent in this context.")}

      true ->
        case parse_args(args) do
          {:error, :runtime_only} ->
            {:ok,
             Result.error(
               "/model takes a model name. To switch runtime without changing model, use /runtime."
             )}

          {:error, {:unknown_runtime, value}} ->
            {:ok,
             Result.error(
               "Unknown runtime '#{value}'. Valid runtimes: #{Enum.join(@valid_runtimes, ", ")}."
             )}

          {:ok, model_spec, []} ->
            {:ok,
             Result.action(
               "Switching to model: #{model_spec}",
               {:switch_model, model_spec}
             )}

          {:ok, model_spec, opts} ->
            label =
              case Keyword.get(opts, :runtime) do
                nil -> "Switching to model: #{model_spec}"
                runtime -> "Switching to model: #{model_spec} (runtime: #{runtime})"
              end

            {:ok, Result.action(label, {:switch_model, model_spec, opts})}
        end
    end
  end

  # Parse "model_spec [runtime=atom]" into {model_spec, opts}. The
  # runtime= keyword can appear anywhere in the arg string; we strip it
  # and treat the remaining whitespace-separated token as the model spec.
  defp parse_args(args) do
    args = String.trim(args)

    tokens = String.split(args, ~r/\s+/, trim: true)

    {kv_tokens, model_tokens} =
      Enum.split_with(tokens, fn t -> String.contains?(t, "=") end)

    with {:ok, opts} <- parse_kvs(kv_tokens, []) do
      case model_tokens do
        [] when opts == [] ->
          # Shouldn't reach here — empty/list dispatched above.
          {:error, :runtime_only}

        [] ->
          # The user gave `runtime=acp` with no model — they wanted
          # /runtime, point them at it.
          {:error, :runtime_only}

        _ ->
          model_spec = Enum.join(model_tokens, " ")
          {:ok, model_spec, opts}
      end
    end
  end

  defp parse_kvs([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_kvs(["runtime=" <> value | rest], acc) do
    value = String.trim(value)

    case runtime_atom(value) do
      {:ok, runtime} -> parse_kvs(rest, [{:runtime, runtime} | acc])
      :error -> {:error, {:unknown_runtime, value}}
    end
  end

  defp parse_kvs([_ignored | rest], acc) do
    # Unknown kv tokens silently skip — leaves room for future kwargs
    # without breaking parse. The model command is permissive about
    # unrecognized switches.
    parse_kvs(rest, acc)
  end

  defp runtime_atom(value) when is_binary(value) do
    case value do
      "arbor" -> {:ok, :arbor}
      "acp" -> {:ok, :acp}
      _ -> :error
    end
  end
end
