defmodule Extensions.Postgres do
  require Logger

  alias Extensions.Postgres.SubscriptionManager
  @default_poll_interval 500

  def default_settings() do
    %{
      "poll_interval" => 100,
      "poll_max_changes" => 100,
      "poll_max_record_bytes" => 1_048_576,
      "publication" => "supabase_multiplayer",
      "slot_name" => "supabase_multiplayer_replication_slot"
    }
  end

  def required_settings() do
    [
      {"region", &is_binary/1},
      {"db_host", &is_binary/1},
      {"db_name", &is_binary/1},
      {"db_user", &is_binary/1},
      {"db_port", &is_binary/1},
      {"db_password", &is_binary/1}
    ]
  end

  def start_distributed(scope, %{"region" => region} = params) do
    [fly_region | _] = Extensions.Postgres.Regions.aws_to_fly(region)
    launch_node = launch_node(fly_region, node())

    Logger.debug(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, fly_region: fly_region)}"
    )

    :rpc.call(launch_node, Extensions.Postgres, :start, [scope, params])
  end

  @doc """
  Start db poller.

  """
  @spec start(String.t(), map()) ::
          :ok | {:error, :already_started}
  def start(scope, %{
        "db_host" => db_host,
        "db_name" => db_name,
        "db_user" => db_user,
        "db_password" => db_pass,
        "poll_interval" => poll_interval,
        "poll_max_changes" => poll_max_changes,
        "poll_max_record_bytes" => poll_max_record_bytes,
        "publication" => publication,
        "slot_name" => slot_name
      }) do
    :global.trans({{Extensions.Postgres, scope}, self()}, fn ->
      case :global.whereis_name({:supervisor, scope}) do
        :undefined ->
          poll_interval =
            if !is_integer(poll_interval) do
              Logger.error("Wrong poll_interval value: #{inspect(poll_interval)}")
              @default_poll_interval
            else
              poll_interval
            end

          opts = [
            id: scope,
            db_host: db_host,
            db_name: db_name,
            db_user: db_user,
            db_pass: db_pass,
            poll_interval: poll_interval,
            publication: publication,
            slot_name: slot_name,
            max_changes: poll_max_changes,
            max_record_bytes: poll_max_record_bytes
          ]

          Logger.debug("Starting Extensions.Postgres, #{inspect(opts, pretty: true)}")

          {:ok, pid} =
            DynamicSupervisor.start_child(Extensions.Postgres.Supervisor, %{
              id: scope,
              start: {Extensions.Postgres.Supervisor, :start_link, [opts]},
              restart: :transient
            })

          :global.register_name({:supervisor, scope}, pid)

        _ ->
          {:error, :already_started}
      end
    end)
  end

  def subscribe(scope, subs_id, topic, claims, transport_pid) do
    pid = manager_pid(scope)

    if pid do
      opts = %{
        topic: topic,
        id: subs_id,
        claims: claims
      }

      # TODO: move inside to SubscriptionManager
      bin_subs_id = UUID.string_to_binary!(subs_id)

      :syn.join(Extensions.Postgres.Subscribers, scope, self(), %{
        bin_id: bin_subs_id,
        transport_pid: transport_pid
      })

      SubscriptionManager.subscribe(pid, opts)
    end
  end

  def unsubscribe(scope, subs_id) do
    pid = manager_pid(scope)

    if pid do
      SubscriptionManager.unsubscribe(pid, subs_id)
    end
  end

  def stop(scope) do
    case :global.whereis_name({:supervisor, scope}) do
      :undefined ->
        nil

      pid ->
        :global.whereis_name({:db_instance, scope})
        |> GenServer.stop(:normal)

        DynamicSupervisor.stop(pid, :shutdown)
    end
  end

  @spec manager_pid(any()) :: pid() | nil
  defp manager_pid(scope) do
    case :global.whereis_name({:subscription_manager, scope}) do
      :undefined ->
        nil

      pid ->
        pid
    end
  end

  def launch_node(fly_region, default) do
    case :syn.members(Extensions.Postgres.RegionNodes, fly_region) do
      [{_, [node: launch_node]} | _] ->
        launch_node

      _ ->
        Logger.warning("Didn't find launch_node, return default #{inspect(default)}")
        default
    end
  end
end
