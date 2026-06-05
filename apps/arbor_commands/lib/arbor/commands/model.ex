defmodule Arbor.Commands.Model do
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

  ## Why this lives in arbor_commands

  Performs side effects — `Arbor.Orchestrator.Session.set_model/2` and,
  if `runtime=` is set, `Session.set_runtime/2`. Direct compile-time
  calls; arbor_commands depends on arbor_orchestrator.
  """
  @behaviour Arbor.Common.Command

  alias Arbor.Commands.Helpers
  alias Arbor.Contracts.Commands.{Context, Result}
  alias Arbor.Orchestrator.Session

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

          {:ok, model_spec, opts} ->
            apply_model(model_spec, opts, ctx)
        end
    end
  end

  defp apply_model(model_spec, opts, %Context{session_pid: pid} = ctx) when is_pid(pid) do
    cond do
      not Process.alive?(pid) ->
        {:ok, Result.error("Cannot switch model: session process is no longer alive.")}

      true ->
        run_model_switch(pid, model_spec, opts, ctx)
    end
  end

  defp apply_model(_model, _opts, _ctx) do
    {:ok, Result.error("Cannot switch model: session pid missing from context.")}
  end

  defp run_model_switch(pid, model_spec, opts, ctx) do
    with {:ok, _} <- safe_call(fn -> Session.set_model(pid, model_spec) end),
         {:ok, runtime_effect} <- maybe_set_runtime(pid, opts, ctx) do
      Helpers.persist_model_config_field(ctx.agent_id, :model, model_spec, "Model")

      effects = [model_changed: model_spec] ++ runtime_effect
      text = build_success_text(model_spec, opts)
      {:ok, Result.ok(text, effects)}
    else
      {:error, :runtime, reason} ->
        {:ok,
         Result.error("Model set to #{model_spec}, but runtime change failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:ok, Result.error("/model failed: #{inspect(reason)}")}
    end
  end

  defp maybe_set_runtime(pid, opts, ctx) do
    case Keyword.get(opts, :runtime) do
      nil ->
        {:ok, []}

      runtime ->
        case safe_call(fn -> Session.set_runtime(pid, runtime) end) do
          {:ok, _} ->
            Helpers.persist_model_config_field(ctx.agent_id, :runtime, runtime, "Model")
            {:ok, [runtime_changed: runtime]}

          {:error, reason} ->
            {:error, :runtime, reason}
        end
    end
  end

  defp build_success_text(model_spec, opts) do
    case Keyword.get(opts, :runtime) do
      nil -> "Model set to #{model_spec} (effective on next turn)."
      runtime -> "Model set to #{model_spec}, runtime set to #{runtime} (effective on next turn)."
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Parse "model_spec [runtime=atom]" into {model_spec, opts}.
  defp parse_args(args) do
    args = String.trim(args)
    tokens = String.split(args, ~r/\s+/, trim: true)

    {kv_tokens, model_tokens} =
      Enum.split_with(tokens, fn t -> String.contains?(t, "=") end)

    with {:ok, opts} <- parse_kvs(kv_tokens, []) do
      case model_tokens do
        [] -> {:error, :runtime_only}
        _ -> {:ok, Enum.join(model_tokens, " "), opts}
      end
    end
  end

  defp parse_kvs([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_kvs(["runtime=" <> value | rest], acc) do
    case runtime_atom(String.trim(value)) do
      {:ok, runtime} -> parse_kvs(rest, [{:runtime, runtime} | acc])
      :error -> {:error, {:unknown_runtime, value}}
    end
  end

  defp parse_kvs([_ignored | rest], acc) do
    # Unknown kv tokens silently skip — leaves room for future kwargs.
    parse_kvs(rest, acc)
  end

  defp runtime_atom("arbor"), do: {:ok, :arbor}
  defp runtime_atom("acp"), do: {:ok, :acp}
  defp runtime_atom(_), do: :error
end
