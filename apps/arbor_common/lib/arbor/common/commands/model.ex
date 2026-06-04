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

          {:ok, model_spec, opts} ->
            apply_model(model_spec, opts, ctx)
        end
    end
  end

  # Side-effecting dispatch — sets model on the Session GenServer and, if
  # opts include :runtime, sets the runtime too. Returns the outcome
  # text + effects list for interfaces to act on. Runtime indirection
  # because arbor_common can't compile-time-depend on arbor_orchestrator.
  defp apply_model(model_spec, opts, %Context{session_pid: pid}) when is_pid(pid) do
    session_mod = Module.concat([:Arbor, :Orchestrator, :Session])

    cond do
      not Code.ensure_loaded?(session_mod) ->
        {:ok, Result.error("Cannot switch model: Session module not loaded.")}

      not Process.alive?(pid) ->
        {:ok, Result.error("Cannot switch model: session process is no longer alive.")}

      true ->
        run_model_switch(session_mod, pid, model_spec, opts)
    end
  end

  defp apply_model(_model, _opts, _ctx) do
    {:ok, Result.error("Cannot switch model: session pid missing from context.")}
  end

  defp run_model_switch(session_mod, pid, model_spec, opts) do
    with {:ok, _} <- safe_call(session_mod, :set_model, [pid, model_spec]),
         {:ok, runtime_effect} <- maybe_set_runtime(session_mod, pid, opts) do
      effects = [model_changed: model_spec] ++ runtime_effect
      text = build_success_text(model_spec, opts)
      {:ok, Result.ok(text, effects)}
    else
      {:error, :model, reason} ->
        {:ok, Result.error("/model failed: #{inspect(reason)}")}

      {:error, :runtime, reason} ->
        {:ok,
         Result.error("Model set to #{model_spec}, but runtime change failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:ok, Result.error("/model failed: #{inspect(reason)}")}
    end
  end

  defp maybe_set_runtime(session_mod, pid, opts) do
    case Keyword.get(opts, :runtime) do
      nil ->
        {:ok, []}

      runtime ->
        case safe_call(session_mod, :set_runtime, [pid, runtime]) do
          {:ok, _} -> {:ok, [runtime_changed: runtime]}
          {:error, reason} -> {:error, :runtime, reason}
        end
    end
  end

  defp build_success_text(model_spec, opts) do
    case Keyword.get(opts, :runtime) do
      nil -> "Model set to #{model_spec} (effective on next turn)."
      runtime -> "Model set to #{model_spec}, runtime set to #{runtime} (effective on next turn)."
    end
  end

  defp safe_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
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
