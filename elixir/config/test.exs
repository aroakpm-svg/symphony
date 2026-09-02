import Config

config :symphony_elixir,
  orchestrator_opts: [identity_validator: fn -> {:ok, %{viewer_id: "test"}} end]
