defmodule Arbor.Agent.NoticeSourceAuthority do
  @moduledoc false
  @behaviour Arbor.Security.Contracts.NativeNoticeSourceAuthorizer
  alias Arbor.Agent.{BranchSupervisor, ProfileStore}

  @mailbox_keys ~w(mailbox_id recipient_subject_id owner_id engagement_id)

  @impl true
  def acquire(principal, owner) do
    with branch when is_pid(branch) <- BranchSupervisor.whereis(principal),
         {:ok, children} <- acknowledged_children(branch),
         role when role in [:session, :heartbeat_service] <-
           Enum.find_value(children, fn
             {id, ^owner, :worker, _} when id in [:session, :heartbeat_service] -> id
             _ -> nil
           end),
         {:ok, mailboxes} <- mailboxes(principal),
         true <- mailboxes != [],
         source = %{
           principal_id: principal,
           owner_pid: owner,
           branch_pid: branch,
           role: role,
           mailboxes: mailboxes
         },
         true <-
           Enum.all?(
             mailboxes,
             &(existing_mailbox?(source, &1) and recheck(source, &1, nil) == :ok)
           ) do
      {:ok, source}
    else
      _ -> {:error, :native_notice_source_required}
    end
  rescue
    _ -> {:error, :native_notice_source_required}
  catch
    _, _ -> {:error, :native_notice_source_required}
  end

  # This read never asks Session, HeartbeatService or its supervisor for state.
  @impl true
  def recheck(source, mailbox, capability) do
    with true <- Process.alive?(source.owner_pid) and Process.alive?(source.branch_pid),
         true <- mailbox in source.mailboxes,
         {:ok, :authorized} <-
           Arbor.Security.recheck_conversation_owner(
             mailbox["recipient_subject_id"],
             source.principal_id,
             mailbox["owner_id"]
           ),
         :ok <- policy(source, mailbox, capability) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp policy(_source, _mailbox, nil), do: :ok

  defp policy(source, mailbox, capability) do
    resource =
      "arbor://comms/notice/publish/#{source.principal_id}/#{mailbox["recipient_subject_id"]}/#{mailbox["owner_id"]}/#{mailbox["engagement_id"]}"

    Arbor.Trust.check_notice_publication_policy(capability, source.principal_id, resource)
  end

  defp mailboxes(principal) do
    with {:ok, %Arbor.Contracts.Persistence.Record{data: snapshot}} <-
           ProfileStore.notice_authority_snapshot(principal),
         %{"agent_id" => ^principal, "notice_mailboxes" => values} <- snapshot,
         true <- is_list(values) and length(values) in 1..16,
         true <- Enum.all?(values, &valid_mailbox?(&1, principal)),
         true <- length(Enum.uniq_by(values, & &1["mailbox_id"])) == length(values) do
      {:ok, values}
    else
      _ -> {:error, :native_notice_source_required}
    end
  end

  defp existing_mailbox?(source, mailbox) do
    match?(
      {:ok, _},
      Arbor.Comms.existing_user_conversation_scope(
        source.principal_id,
        mailbox["owner_id"],
        mailbox["engagement_id"]
      )
    )
  end

  defp valid_mailbox?(value, principal) when is_map(value) and not is_struct(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@mailbox_keys) and
      match?({:ok, _}, Arbor.Security.validate_native_notice_mailbox(principal, value))
  end

  defp valid_mailbox?(_, _), do: false

  # Acquisition only, after parent acknowledgement. Run the public topology
  # call in a bounded helper so teardown cannot hold the lower broker forever.
  defp acknowledged_children(branch) do
    task = Task.async(fn -> Supervisor.which_children(branch) end)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, children} when is_list(children) -> {:ok, children}
      _ -> {:error, :native_notice_source_required}
    end
  end
end
