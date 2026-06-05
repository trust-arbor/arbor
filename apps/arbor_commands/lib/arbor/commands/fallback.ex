defmodule Arbor.Commands.Fallback do
  @moduledoc """
  View and edit the current agent's LLM fallback chain.

  The fallback chain is an ordered list of override entries the
  `Arbor.AI.Runtime.Dispatch` selection layer walks through when the
  primary attempt fails with a fallback-eligible error. Each entry can
  override `:runtime`, `:provider`, and/or `:model`.

  ## Usage

      /fallback                         # show current chain
      /fallback show                    # same as above
      /fallback set <entries>           # replace the entire chain
      /fallback add <entry>             # append a single entry
      /fallback remove <index>          # remove entry by 0-based index
      /fallback clear                   # empty the chain
      /fallback preview                 # show what each entry would resolve to

  ## Entry syntax

  An entry is a comma-separated list of `key=value` pairs. Multiple
  entries (for `set`) are separated by semicolons:

      /fallback add runtime=acp
      /fallback add provider=openai,model=gpt-4o
      /fallback set runtime=acp ; model=claude-sonnet-4-6 ; provider=openai

  ## Persistence

  Edits land on the running session immediately (effective next turn /
  heartbeat) AND are persisted to the agent's profile via
  `Arbor.Agent.ProfileStore`, so the chain survives across agent
  restarts and resumes. Heartbeat resolution reads the persisted chain
  via `Lifecycle.resolve_fallback_chain/2`.

  ## Why this lives in arbor_commands

  Performs side effects via `Arbor.Orchestrator.Session.set_fallback_chain/2`
  and `Arbor.Agent.ProfileStore.store_profile/1`. arbor_commands depends
  on both arbor_orchestrator and arbor_agent, so these calls are
  compile-time-checked.

  ## Preview

  `/fallback preview` enumerates `Arbor.AI.Runtime.Dispatch.enumerate_chain/2`
  against the current model to show what each entry WOULD resolve to.
  Useful before committing a `set` — same machinery `mix arbor.doctor
  --model X --fallback ...` uses, just inside the chat UI.
  """

  @behaviour Arbor.Common.Command

  alias Arbor.Commands.Helpers
  alias Arbor.Contracts.Commands.{Context, Result}
  alias Arbor.Orchestrator.Session

  @impl true
  def name, do: "fallback"

  @impl true
  def description, do: "Show or edit the agent's LLM fallback chain"

  @impl true
  def usage do
    "/fallback [show | set <entries> | add <entry> | remove <i> | clear | preview]"
  end

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute("", ctx), do: execute("show", ctx)

  def execute(args, %Context{} = ctx) when is_binary(args) do
    case String.split(args, " ", parts: 2) do
      ["show"] -> handle_show(ctx)
      ["show", _rest] -> handle_show(ctx)
      ["clear"] -> handle_clear(ctx)
      ["preview"] -> handle_preview(ctx)
      ["preview", _rest] -> handle_preview(ctx)
      ["set", rest] -> handle_set(rest, ctx)
      ["add", rest] -> handle_add(rest, ctx)
      ["remove", rest] -> handle_remove(rest, ctx)
      [other] -> {:ok, unknown_subcommand_error(other)}
      _ -> {:ok, unknown_subcommand_error(args)}
    end
  end

  # ── Subcommand handlers ─────────────────────────────────────────────

  defp handle_show(ctx) do
    with {:ok, pid} <- session_pid(ctx),
         {:ok, chain} <- safe_call(fn -> Session.get_fallback_chain(pid) end) do
      {:ok, Result.ok(render_chain(chain))}
    else
      {:error, reason} -> {:ok, Result.error("/fallback show failed: #{inspect(reason)}")}
    end
  end

  defp handle_clear(ctx) do
    apply_chain([], ctx, "Fallback chain cleared.")
  end

  defp handle_set(rest, ctx) do
    case parse_entries(rest) do
      {:ok, []} ->
        {:ok,
         Result.error("/fallback set needs at least one entry — use /fallback clear to empty.")}

      {:ok, entries} ->
        apply_chain(
          entries,
          ctx,
          "Fallback chain set to #{length(entries)} entries (effective on next turn)."
        )

      {:error, reason} ->
        {:ok, Result.error("/fallback set: #{reason}")}
    end
  end

  defp handle_add(rest, ctx) do
    case parse_entry(rest) do
      {:ok, entry} ->
        with {:ok, pid} <- session_pid(ctx),
             {:ok, current} <- safe_call(fn -> Session.get_fallback_chain(pid) end) do
          new_chain = current ++ [entry]

          apply_chain(
            new_chain,
            ctx,
            "Added entry #{inspect(entry)} (chain is now #{length(new_chain)} entries)."
          )
        else
          {:error, reason} -> {:ok, Result.error("/fallback add failed: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:ok, Result.error("/fallback add: #{reason}")}
    end
  end

  defp handle_remove(rest, ctx) do
    case Integer.parse(String.trim(rest)) do
      {idx, ""} when idx >= 0 ->
        with {:ok, pid} <- session_pid(ctx),
             {:ok, current} <- safe_call(fn -> Session.get_fallback_chain(pid) end) do
          if idx >= length(current) do
            {:ok,
             Result.error(
               "/fallback remove: index #{idx} out of range (chain has #{length(current)} entries)."
             )}
          else
            new_chain = List.delete_at(current, idx)
            apply_chain(new_chain, ctx, "Removed entry at index #{idx}.")
          end
        else
          {:error, reason} -> {:ok, Result.error("/fallback remove failed: #{inspect(reason)}")}
        end

      _ ->
        {:ok,
         Result.error(
           "/fallback remove needs a non-negative integer index (e.g. /fallback remove 0)."
         )}
    end
  end

  defp handle_preview(ctx) do
    with {:ok, pid} <- session_pid(ctx),
         {:ok, chain} <- safe_call(fn -> Session.get_fallback_chain(pid) end) do
      case current_model(ctx) do
        nil ->
          {:ok,
           Result.error("/fallback preview needs a current model — set one with /model first.")}

        model ->
          if enumerate_chain_available?() do
            policy = %{fallback_chain: chain}
            results = apply(Arbor.AI.Runtime.Dispatch, :enumerate_chain, [model, policy])
            {:ok, Result.ok(render_preview(model, results))}
          else
            {:ok, Result.error("/fallback preview: Arbor.AI.Runtime.Dispatch not loaded.")}
          end
      end
    else
      {:error, reason} -> {:ok, Result.error("/fallback preview failed: #{inspect(reason)}")}
    end
  end

  # ── Persist + apply ─────────────────────────────────────────────────

  # The chain is applied to the live session AND persisted to the
  # agent's profile so it survives restarts.
  defp apply_chain(chain, %Context{} = ctx, success_msg) do
    with {:ok, pid} <- session_pid(ctx),
         {:ok, _} <- safe_call(fn -> Session.set_fallback_chain(pid, chain) end) do
      persist_to_profile(ctx, chain)

      {:ok,
       Result.ok(
         success_msg <> "\n\n" <> render_chain(chain),
         fallback_chain_changed: chain
       )}
    else
      {:error, reason} -> {:ok, Result.error("/fallback failed: #{inspect(reason)}")}
    end
  end

  defp persist_to_profile(%Context{agent_id: agent_id}, chain) do
    Helpers.persist_model_config_field(agent_id, :fallback_chain, chain, "Fallback")
  end

  # ── Output rendering ────────────────────────────────────────────────

  defp render_chain([]) do
    "Current fallback chain: empty.\n" <>
      "Add an entry with `/fallback add <key=value,...>` (e.g. `/fallback add runtime=acp`)."
  end

  defp render_chain(chain) do
    rows =
      chain
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {entry, idx} -> "  #{idx}: #{inspect(entry)}" end)

    "Current fallback chain (#{length(chain)} entries):\n" <> rows
  end

  defp render_preview(model, results) do
    header =
      "Selection preview for #{model} (#{length(results)} attempts):"

    rows =
      results
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {entry, idx} -> "  #{idx}: " <> render_preview_row(entry) end)

    header <> "\n" <> rows
  end

  defp render_preview_row({:ok, %{override: marker, model_entry: me, selection: sel}}) do
    "#{label_for(marker)} → " <>
      "model=#{me.canonical_id}, provider=#{sel.provider.id}, runtime=:#{sel.runtime}"
  end

  defp render_preview_row({:error, reason, marker}) do
    "#{label_for(marker)} → ERROR: #{inspect(reason)}"
  end

  defp label_for(:primary), do: "primary"
  defp label_for(override) when is_map(override), do: inspect(override)

  # ── Entry parsing ───────────────────────────────────────────────────

  # `/fallback set` takes a semicolon-separated list of entries. Each
  # entry is its own comma-separated key=value list (same shape as the
  # `--fallback` flag in `mix arbor.doctor`).
  defp parse_entries(str) do
    str
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, []}, fn entry_str, {:ok, acc} ->
      case parse_entry(entry_str) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_entry(str) do
    cleaned = String.trim(str)

    if cleaned == "" do
      {:error, "empty entry"}
    else
      entry =
        cleaned
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn pair, acc ->
          case String.split(pair, "=", parts: 2) do
            [k, v] ->
              key = String.trim(k) |> safe_existing_atom()
              value = String.trim(v)

              if key && key in [:runtime, :provider, :model] do
                case coerce_value(key, value) do
                  nil -> acc
                  coerced -> Map.put(acc, key, coerced)
                end
              else
                acc
              end

            _ ->
              acc
          end
        end)

      if entry == %{} do
        {:error, "no recognized fields (use runtime=, provider=, model=)"}
      else
        {:ok, entry}
      end
    end
  end

  defp coerce_value(:runtime, value), do: safe_existing_atom(value)
  defp coerce_value(:provider, value), do: safe_existing_atom(value)
  defp coerce_value(:model, value), do: value

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp session_pid(%Context{session_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      {:error, "session process is no longer alive"}
    end
  end

  defp session_pid(_ctx), do: {:error, "session pid missing from context"}

  defp current_model(%Context{} = ctx), do: Map.get(ctx, :model)

  defp enumerate_chain_available? do
    Code.ensure_loaded?(Arbor.AI.Runtime.Dispatch) and
      function_exported?(Arbor.AI.Runtime.Dispatch, :enumerate_chain, 2)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp unknown_subcommand_error(input) do
    Result.error(
      "/fallback: unknown subcommand '#{String.trim(input)}'. " <>
        "Use show, set, add, remove, clear, or preview."
    )
  end
end
