defmodule Telegram.Webhook do
  @moduledoc """
  Telegram Webhook supervisor.

  ## Usage

  ### WebServer adapter

  Two `Plug` compatible webserver are supported:

  - `Telegram.WebServer.Bandit`: use `Bandit`
  - `Telegram.WebServer.Cowboy` (default): use `Plug.Cowboy`

  You should configure the desired webserver adapter in you app configuration:

  ```elixir
  config :telegram,
    webserver: Telegram.WebServer.Bandit

  # OR

  config :telegram,
    webserver: Telegram.WebServer.Cowboy
  ```

  and include in you dependencies one of:

  ```elixir
  {:plug_cowboy, "~> 2.5"}

  # OR

  {:bandit, "~> 1.0-pre"}
  ```

  ### Supervision tree

  In you app supervision tree:

  ```elixir
  webhook_config = [
    host: "myapp.public-domain.com",
    port: 443,
    local_port: 4_000
  ]

  bot_config = [
    token: Application.fetch_env!(:my_app, :token_counter_bot),
    max_bot_concurrency: Application.fetch_env!(:my_app, :max_bot_concurrency)
  ]

  children = [
    {Telegram.Webhook, config: webhook_config, bots: [{MyApp.Bot, bot_config}]}
    ...
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
  ```

  ## Ref
  - https://core.telegram.org/bots/api#setwebhook
  - https://core.telegram.org/bots/webhooks
  """

  alias Telegram.Types
  import Telegram.Utils, only: [retry: 1]
  require Logger

  use Supervisor

  @telegram_webhook_params [:certificate, :ip_address, :max_connections, :allowed_updates, :drop_pending_updates, :secret_token]

  @default_port 443
  @default_local_port 4000

  @default_config [
    port: @default_port,
    local_port: @default_local_port,
    set_webhook: true
  ]

  @typedoc """
  Webhook configuration.
  
  - all telegram setWebhook parameters: https://core.telegram.org/bots/api#setwebhook (except url)
  - `hostname`: hostname for webhook url
  - `port`: (reverse proxy) port of the HTTPS webhook url (optional, default: #{@default_port})
  - `local_port`: (backend) port of the application HTTP web server (optional, default: #{@default_local_port})
  """

  @type config :: [
          host: String.t(),
          port: :inet.port_number(),
          local_port: :inet.port_number(),
          set_webhook: boolean()
        ]

  @spec start_link(config: config(), bots: [Types.bot_spec()]) :: Supervisor.on_start()
  def start_link(config: config, bots: bot_specs) do
    Supervisor.start_link(__MODULE__, {config, bot_specs}, name: __MODULE__)
  end

  @impl Supervisor
  def init({config, bot_specs}) do
    config = Keyword.merge(@default_config, config)
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)
    local_port = Keyword.fetch!(config, :local_port)

    telegram_webhook_params = Enum.filter(config, fn {param, _} -> param in @telegram_webhook_params end)

    set_webhook? = Keyword.fetch!(config, :set_webhook)

    bot_routing_map =
      bot_specs
      |> Map.new(fn {bot_behaviour_mod, opts} ->
        token = Keyword.fetch!(opts, :token)
        url_token = Keyword.get(opts, :url_token, :crypto.hash(:sha, :erlang.term_to_binary(token)) |> Base.url_encode64(padding: false))
        {url_token, {token, bot_behaviour_mod}}
      end)

    bot_routing_map
    |> Enum.each(fn {url_token, {token, bot_behaviour_mod}} ->
      url = %URI{scheme: "https", host: host, path: "/telegram/#{url_token}", port: port} |> to_string()
      webhook_params = Keyword.put(telegram_webhook_params, :url, url)
      Logger.info("Running in webhook mode: #{inspect(webhook_params)}", bot: bot_behaviour_mod, token: token)

      if set_webhook? do
        # coveralls-ignore-start
        set_webhook(token, webhook_params)
        # coveralls-ignore-stop
      else
        Logger.info("Skipped setWebhook as requested via config.set_webhook", bot: bot_behaviour_mod, token: token)
      end
    end)

    webserver = Application.get_env(:telegram, :webserver, Telegram.WebServer.Bandit)
    webserver_spec = webserver.child_spec(local_port, bot_routing_map)

    children = bot_specs ++ [webserver_spec]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # coveralls-ignore-start

  defp set_webhook(token, webhook_params) do
    {:ok, _} = retry(fn -> Telegram.Api.request(token, "setWebhook", webhook_params) end)
  end

  # coveralls-ignore-stop
end

defmodule Telegram.Webhook.Router do
  @moduledoc false

  require Logger

  use Plug.Router, copy_opts_to_assign: :bot_routing_map

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug :dispatch

  post "/telegram/:url_token" do
    update = conn.body_params
    bot_routing_map = conn.assigns.bot_routing_map
    {token, bot_dispatch_behaviour} = bot_routing_map[url_token]

    Logger.debug("received update: #{inspect(update)}", bot: inspect(bot_dispatch_behaviour))

    if bot_dispatch_behaviour == nil do
      Plug.Conn.send_resp(conn, :not_found, "")
    else
      bot_dispatch_behaviour.dispatch_update(update, token)
      Plug.Conn.send_resp(conn, :ok, "")
    end
  end

  # coveralls-ignore-start

  match _ do
    Plug.Conn.send_resp(conn, :not_found, "")
  end

  # coveralls-ignore-stop
end