defmodule Arbor.Actions.Scheduler do
  @moduledoc false
  alias Arbor.Actions.Config

  @modules [__MODULE__.EnqueueRoutine, __MODULE__.ListRoutines, __MODULE__.CancelRoutine]

  # Called only by the source executor to produce the exact second proof.
  # Nothing callable is passed into Action.run; the action receives signed data.
  def prepare_request(module, params, principal) when module in @modules do
    scheduler = Config.scheduler_module()

    with {:ok, operation, value} <- request_value(module, params, principal, scheduler),
         {:ok, payload} <- scheduler.routine_request_payload(operation, value) do
      {:ok, %{operation: operation, value: value, payload: payload}}
    end
  end

  def prepare_request(_, _, _), do: :not_a_routine_action

  defp request_value(
         __MODULE__.EnqueueRoutine,
         %{routine: routine, scheduled_at: at, request_id: id} = params,
         principal,
         scheduler
       )
       when map_size(params) == 3 do
    with {:ok, intent} <- scheduler.prepare_routine_intent(principal, routine, at, id),
         do: {:ok, :enqueue, intent}
  end

  defp request_value(__MODULE__.ListRoutines, params, _principal, _scheduler)
       when map_size(params) <= 2 do
    if Enum.all?(Map.keys(params), &(&1 in [:limit, :before_id])),
      do:
        {:ok, :list,
         %{"limit" => Map.get(params, :limit, 20), "before_id" => Map.get(params, :before_id)}},
      else: {:error, :invalid_routine_filters}
  end

  defp request_value(__MODULE__.CancelRoutine, %{job_id: id} = params, _principal, _scheduler)
       when map_size(params) == 1, do: {:ok, :cancel, id}

  defp request_value(_, _, _, _), do: {:error, :invalid_routine_parameters}

  def run_request(module, params, context) do
    with {:ok, principal} <- Arbor.Actions.authorized_principal(context, module),
         %{
           operation: operation,
           value: value,
           proof: %Arbor.Contracts.Security.SignedRequest{agent_id: ^principal} = proof
         } <-
           Map.get(context, :routine_request),
         :ok <- parameter_binding(module, params, value) do
      scheduler = Config.scheduler_module()

      case operation do
        :enqueue when module == __MODULE__.EnqueueRoutine ->
          scheduler.enqueue_routine(value, proof)

        :list when module == __MODULE__.ListRoutines ->
          scheduler.list_owned_routines(value, proof)

        :cancel when module == __MODULE__.CancelRoutine ->
          case scheduler.cancel_owned_routine(value, proof) do
            :ok -> {:ok, %{job_id: value, cancelled: true}}
            error -> error
          end

        _ ->
          {:error, :invalid_routine_request}
      end
    else
      _ -> {:error, :routine_request_proof_required}
    end
  end

  defp parameter_binding(__MODULE__.EnqueueRoutine, params, value) do
    if params.routine == value["routine"] and params.scheduled_at == value["scheduled_at"] and
         params.request_id == value["request_id"],
       do: :ok,
       else: {:error, :routine_parameters_changed}
  end

  defp parameter_binding(__MODULE__.ListRoutines, params, value) do
    if Map.get(params, :limit, 20) == value["limit"] and
         Map.get(params, :before_id) == value["before_id"],
       do: :ok,
       else: {:error, :routine_parameters_changed}
  end

  defp parameter_binding(__MODULE__.CancelRoutine, params, value),
    do: if(params.job_id == value, do: :ok, else: {:error, :routine_parameters_changed})

  defmodule EnqueueRoutine do
    @moduledoc false

    alias Arbor.Actions.Scheduler

    use Jido.Action,
      name: "scheduler_enqueue_routine",
      description:
        "Schedule the reviewed local morning digest at an absolute UTC time; request_id makes retries idempotent",
      category: "scheduler",
      schema: [
        routine: [type: :string, required: true],
        scheduled_at: [type: :string, required: true],
        request_id: [type: :string, required: true]
      ]

    def requires_authenticated_principal?, do: true
    def effect_class, do: :local_write
    def taint_roles, do: %{routine: :control, scheduled_at: :data, request_id: :data}
    def run(params, context), do: Scheduler.run_request(__MODULE__, params, context)
  end

  defmodule ListRoutines do
    @moduledoc false

    alias Arbor.Actions.Scheduler

    use Jido.Action,
      name: "scheduler_list_routines",
      description: "List your own authenticated scheduled routines",
      category: "scheduler",
      schema: [limit: [type: :integer, default: 20], before_id: [type: :integer]]

    def requires_authenticated_principal?, do: true
    def effect_class, do: :read_only
    def run(params, context), do: Scheduler.run_request(__MODULE__, params, context)
  end

  defmodule CancelRoutine do
    @moduledoc false

    alias Arbor.Actions.Scheduler

    use Jido.Action,
      name: "scheduler_cancel_routine",
      description:
        "Cancel your own scheduled routine; effects already admitted are not rolled back",
      category: "scheduler",
      schema: [job_id: [type: :integer, required: true]]

    def requires_authenticated_principal?, do: true
    def effect_class, do: :local_write
    def run(params, context), do: Scheduler.run_request(__MODULE__, params, context)
  end
end
