defmodule Arbor.Gateway.Dev.Router do
  @moduledoc """
  Development tools HTTP router.

  Provides endpoints for runtime inspection and code evaluation.
  Mounted at `/api/dev` by the main Gateway router.

  All endpoints are restricted to:
  - Development environment only (`Mix.env() == :dev`)
  - Localhost requests only

  ## Endpoints

  - `POST /eval` — evaluate Elixir code in the running VM
  - `POST /recompile` — recompile the project
  - `GET /info` — runtime information (processes, memory, apps)
  - `GET /config/:app` — application configuration
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  # POST /api/dev/eval — Evaluate Elixir code
  #
  # Request body: {"code": "Enum.map(1..5, & &1 * 2)"}
  # Response: {"result": "[2, 4, 6, 8, 10]", "status": "ok"}
  post "/eval" do
    with :ok <- check_dev_environment(),
         :ok <- check_localhost(conn) do
      code = conn.body_params["code"] || ""
      Logger.info("Dev eval request", code: String.slice(code, 0, 100))

      case safe_eval(code) do
        {:ok, result} ->
          json_response(conn, 200, %{status: "ok", result: inspect(result, pretty: true)})

        {:error, error} ->
          json_response(conn, 422, %{status: "error", error: error})
      end
    else
      {:error, reason} ->
        json_response(conn, 403, %{status: "forbidden", reason: reason})
    end
  end

  # POST /api/dev/recompile — Recompile the project
  #
  # Response: {"status": "ok", "result": ":ok"}
  post "/recompile" do
    with :ok <- check_dev_environment(),
         :ok <- check_localhost(conn) do
      Logger.info("Dev recompile request")

      result = IEx.Helpers.recompile()
      json_response(conn, 200, %{status: "ok", result: inspect(result)})
    else
      {:error, reason} ->
        json_response(conn, 403, %{status: "forbidden", reason: reason})
    end
  end

  # GET /api/dev/info — Runtime system information
  #
  # Response: {"processes": 123, "memory_mb": 45.6, "uptime_seconds": 3600, ...}
  get "/info" do
    with :ok <- check_dev_environment(),
         :ok <- check_localhost(conn) do
      info = %{
        processes: :erlang.system_info(:process_count),
        process_limit: :erlang.system_info(:process_limit),
        memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 2),
        memory_breakdown: memory_breakdown(),
        uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
        schedulers: :erlang.system_info(:schedulers_online),
        otp_release: :erlang.system_info(:otp_release) |> to_string(),
        elixir_version: System.version(),
        node: node() |> to_string(),
        applications: running_applications()
      }

      json_response(conn, 200, info)
    else
      {:error, reason} ->
        json_response(conn, 403, %{status: "forbidden", reason: reason})
    end
  end

  # GET /api/dev/config/:app — Application configuration
  #
  # Response: {"app": "arbor_comms", "config": {...}}
  get "/config/:app" do
    with :ok <- check_dev_environment(),
         :ok <- check_localhost(conn) do
      case safe_get_config(app) do
        {:ok, config} ->
          json_response(conn, 200, %{app: app, config: inspect(config, pretty: true)})

        {:error, reason} ->
          json_response(conn, 404, %{status: "error", reason: reason})
      end
    else
      {:error, reason} ->
        json_response(conn, 403, %{status: "forbidden", reason: reason})
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  defp check_dev_environment do
    allowed = Application.get_env(:arbor_gateway, :dev_endpoints, Mix.env() == :dev)

    if allowed do
      :ok
    else
      {:error, "Dev endpoints are only available in development"}
    end
  end

  defp check_localhost(conn) do
    remote_ip = conn.remote_ip

    if remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      :ok
    else
      Logger.warning("Dev endpoint access denied from #{inspect(remote_ip)}")
      {:error, "Dev endpoints are restricted to localhost"}
    end
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
  defp safe_eval(code) when is_binary(code) and byte_size(code) > 0 do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    {result, _bindings} = Code.eval_string(code)
    {:ok, result}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp safe_eval(_), do: {:error, "No code provided"}

  defp safe_get_config(app_name) when is_binary(app_name) do
    # Only allow known arbor apps
    allowed_apps = ~w(
      arbor_gateway arbor_comms arbor_ai arbor_trust arbor_security
      arbor_signals arbor_common arbor_contracts arbor_persistence
      arbor_consensus arbor_historian arbor_agent arbor_actions
      arbor_shell arbor_web arbor_sandbox arbor_eval
    )

    if app_name in allowed_apps do
      atom = String.to_existing_atom(app_name)
      {:ok, Application.get_all_env(atom)}
    else
      {:error, "Unknown application: #{app_name}"}
    end
  rescue
    ArgumentError -> {:error, "Unknown application: #{app_name}"}
  end

  defp memory_breakdown do
    %{
      processes_mb: Float.round(:erlang.memory(:processes) / 1_048_576, 2),
      ets_mb: Float.round(:erlang.memory(:ets) / 1_048_576, 2),
      atom_mb: Float.round(:erlang.memory(:atom) / 1_048_576, 2),
      binary_mb: Float.round(:erlang.memory(:binary) / 1_048_576, 2),
      code_mb: Float.round(:erlang.memory(:code) / 1_048_576, 2)
    }
  end

  defp running_applications do
    Application.started_applications()
    |> Enum.map(fn {app, _desc, vsn} ->
      %{name: to_string(app), version: to_string(vsn)}
    end)
    |> Enum.filter(fn %{name: name} -> String.starts_with?(name, "arbor") end)
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
