defmodule Arbor.Consensus.Helpers do
  @moduledoc """
  Convenience helpers for consensus operations.

  `await/2` provides ergonomic synchronous waiting for test code
  and scripts. For production agent code, prefer the async pattern
  with signal subscriptions.

  ## Usage

      # Submit a proposal and wait for the result
      {:ok, id} = Consensus.propose(%{...})
      {:ok, decision} = Helpers.await(id, timeout: 5_000)

      # Ask an advisory question and wait
      {:ok, id} = Consensus.ask("Should we add caching?")
      {:ok, decision} = Helpers.await(id)
  """

  @doc """
  Wait for a proposal's decision. Wraps `Arbor.Consensus.await/2`.

  ## Options

    * `:timeout` - Maximum wait time in ms (default: 30_000)
    * `:server` - Coordinator server

  ## Examples

      {:ok, id} = Consensus.propose(%{...})
      {:ok, decision} = Helpers.await(id, timeout: 5_000)
  """
  @spec await(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def await(proposal_id, opts \\ []) do
    Arbor.Consensus.await(proposal_id, opts)
  end

  @doc """
  Submit a proposal and wait for the decision in one call.

  Convenience function that combines `propose/2` and `await/2`.

  ## Options

    * `:timeout` - Maximum wait time in ms (default: 30_000)
    * `:server` - Coordinator server
    * All other options are passed to `propose/2`

  ## Examples

      {:ok, decision} = Helpers.propose_and_await(%{
        proposer: "agent_1",
        description: "Add caching"
      }, timeout: 10_000)
  """
  @spec propose_and_await(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def propose_and_await(attrs, opts \\ []) do
    {timeout, submit_opts} = Keyword.pop(opts, :timeout, 30_000)
    server = Keyword.get(opts, :server)

    case Arbor.Consensus.propose(attrs, submit_opts) do
      {:ok, proposal_id} ->
        await_opts = [timeout: timeout]
        await_opts = if server, do: Keyword.put(await_opts, :server, server), else: await_opts
        await(proposal_id, await_opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Ask an advisory question and wait for the response in one call.

  Convenience function that combines `ask/2` and `await/2`.

  ## Options

    * `:timeout` - Maximum wait time in ms (default: 30_000)
    * `:server` - Coordinator server
    * All other options are passed to `ask/2`

  ## Examples

      {:ok, decision} = Helpers.ask_and_await(
        "Should we enable feature X?",
        context: %{feature: "X"},
        timeout: 10_000
      )
  """
  @spec ask_and_await(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def ask_and_await(description, opts \\ []) do
    {timeout, submit_opts} = Keyword.pop(opts, :timeout, 30_000)
    server = Keyword.get(opts, :server)

    case Arbor.Consensus.ask(description, submit_opts) do
      {:ok, proposal_id} ->
        await_opts = [timeout: timeout]
        await_opts = if server, do: Keyword.put(await_opts, :server, server), else: await_opts
        await(proposal_id, await_opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Run a binding council decision and return the result synchronously.

  Convenience wrapper around `Arbor.Consensus.decide/2`. Since the DOT engine
  pipeline runs synchronously (blocking until all perspectives complete and
  votes are tallied), no separate await step is needed.

  ## Options

    * `:graph` — path to custom council DOT file
    * `:quorum` — "majority" | "supermajority" | "unanimous"
    * `:mode` — "decision" | "advisory"
    * `:timeout` — engine timeout in ms (default: 600_000)

  ## Examples

      {:ok, decision} = Helpers.decide("Should Arbor add a Redis dependency?")
      decision.decision  # => "approved" | "rejected" | "deadlock"
  """
  @spec decide(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(description, opts \\ []) do
    Arbor.Consensus.decide(description, opts)
  end
end
