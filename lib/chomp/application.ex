defmodule Chomp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ChompWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:chomp, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Chomp.PubSub},
      Chomp.Video,
      ChompWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Chomp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChompWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
