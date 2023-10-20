defmodule Telegram.Bot.ChatBot.Chat.Session.Server do
  @moduledoc false

  use GenServer, restart: :transient
  require Logger
  alias Telegram.Bot.{ChatBot.Chat, Utils}
  alias Telegram.{ChatBot, Types}

  defmodule State do
    @moduledoc false

    @enforce_keys [:chatbot_behaviour, :token, :chat_process_id, :bot_state]
    defstruct @enforce_keys
  end

  @spec start_link({ChatBot.t(), Types.token(), ChatBot.chat_process_id(), Types.update()}) :: GenServer.on_start()
  def start_link({chatbot_behaviour, token, chat_process_id, update}) do
    GenServer.start_link(
      __MODULE__,
      {chatbot_behaviour, token, chat_process_id, update},
      name: Chat.Registry.via(token, chat_process_id)
    )
  end

  @spec handle_update(ChatBot.t(), Types.token(), Types.update()) :: any()
  def handle_update(chatbot_behaviour, token, update) do
    with {:get_chat_session_server, {:ok, server}} <-
           {:get_chat_session_server, get_chat_session_server(chatbot_behaviour, token, update)} do # add update to server process
      GenServer.cast(server, {:handle_update, update}) # line 53
    else
      {:get_chat_session_server, {:error, :max_children}} ->
        Logger.info("Reached max children, update dropped", bot: chatbot_behaviour, token: token)
    end
  end

  @impl GenServer
  def init({chatbot_behaviour, token, chat_process_id, update}) do
    Logger.metadata(bot: chatbot_behaviour, chat_process_id: chat_process_id)

    state = %State{token: token, chatbot_behaviour: chatbot_behaviour, chat_process_id: chat_process_id, bot_state: nil}

    chatbot_behaviour.init(update)
    |> case do
      {:ok, bot_state} ->
        {:ok, put_in(state.bot_state, bot_state)} # put_in() returns modified %State{} with a new bot_state value

      {:ok, bot_state, timeout} ->
        {:ok, put_in(state.bot_state, bot_state), timeout}
    end
  end

  @impl GenServer
  def handle_cast({:handle_update, update}, %State{} = state) do
    try do
      res =    
        try do
          case state.chatbot_behaviour.before_update(update, state.token, state.bot_state) do
            {:ok, before_bot_state} -> # continue mainstream handle
              state.chatbot_behaviour.handle_update(update, state.token, before_bot_state) # chat_bot.ex line 88 = your bot
            {:callback_query, res} -> # callback query
              res
            {:context_exec, res} -> # context inheritance
              res
          end
        catch
          :throw, {:redirect, {function, module, args}} -> apply(module, function, args)
        end
  		processed_bot_state = elem(res, 1)
      after_bot_state = state.chatbot_behaviour.after_update(update, state.token, processed_bot_state)
  		res = put_elem(res, 1, after_bot_state) # Replace original processed bot_state with after_update's
  		handle_callback_result(res, state)
    catch
      :error, err ->
        stacktrace = Exception.format(:error, err, __STACKTRACE__)
        Logger.error(stacktrace)
        res = state.chatbot_behaviour.handle_error(err, stacktrace, update, state.token, state.chat_process_id, state.bot_state)
        handle_callback_result(res, state)
    end
  end

  @impl GenServer
  def handle_info(:timeout, %State{} = state) do
    Logger.debug("Reached timeout")

    res = state.chatbot_behaviour.handle_timeout(state.token, state.chat_process_id, state.bot_state)
    handle_callback_result(res, state)
  end

  @impl GenServer
  def handle_info(msg, %State{} = state) do
    res = state.chatbot_behaviour.handle_info(msg, state.token, state.chat_process_id, state.bot_state)
    handle_callback_result(res, state)
  end

  defp get_chat_session_server(chatbot_behaviour, token, update) do
		with {:get_chat_process_id, {:ok, %{"id" => chat_process_id}}} <- {:get_chat_process_id, Utils.get_chat(update)||Utils.get_user(update)} do
	    Chat.Registry.lookup(token, chat_process_id)
	    |> case do
	      {:ok, _server} = ok ->
	        ok

	      {:error, :not_found} ->
	        start_chat_session_server(chatbot_behaviour, token, chat_process_id, update)
	    end
		else
			{:get_chat_process_id, nil} ->
				Logger.info("Dropped update without even a user #{inspect(update)}", bot: chatbot_behaviour, token: token)
		end
  end

  defp start_chat_session_server(chatbot_behaviour, token, chat_process_id, update) do
    child_spec = {__MODULE__, {chatbot_behaviour, token, chat_process_id, update}} # lines 17 -> 37

    Chat.Session.Supervisor.start_child(child_spec, token)
    |> case do
      {:ok, _server} = ok ->
        ok

      {:error, :max_children} = error ->
        error
    end
  end

  defp handle_callback_result(result, %State{} = state) do
    case result do
      {:ok, bot_state} ->
        {:noreply, put_in(state.bot_state, bot_state)}

      {:ok, bot_state, timeout} ->
        {:noreply, put_in(state.bot_state, bot_state), timeout}

      {:stop, bot_state} ->
        Chat.Registry.unregister(state.token, state.chat_process_id)
        {:stop, :normal, put_in(state.bot_state, bot_state)}
    end
  end
end
