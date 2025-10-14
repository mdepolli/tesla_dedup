defmodule TeslaDedup.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TeslaDedup.Server
    ]

    opts = [strategy: :one_for_one, name: TeslaDedup.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
