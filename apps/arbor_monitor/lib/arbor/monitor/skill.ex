defmodule Arbor.Monitor.Skill do
  @moduledoc """
  Behaviour for monitoring skills.

  Skills are stateless — pure functions that wrap recon/erlang calls
  for metric collection and anomaly checking.
  """

  @type severity :: :warning | :critical | :emergency

  @type anomaly_result :: :normal | {:anomaly, severity(), details :: map()}

  @callback name() :: atom()

  @callback collect() :: {:ok, map()} | {:error, term()}

  @callback check(metrics :: map()) :: anomaly_result()
end
