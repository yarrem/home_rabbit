defmodule HomeRabbit.Exchange do
  alias AMQP.Basic

  @callback get_queue(
              queue ::
                Basic.queue()
                | {queue :: Basic.queue(), routing_key :: Basic.routing_key()}
                | {queue :: Basic.queue(), arguments :: [{key :: String.t(), value :: term}, ...],
                   x_match :: {String.t(), String.t()}}
            ) :: Basic.queue()

  @callback bind_queue(
              channel :: Basic.channel(),
              queue ::
                Basic.queue()
                | {queue :: Basic.queue(), routing_key :: Basic.routing_key()}
                | {queue :: Basic.queue(), arguments :: [{key :: String.t(), value :: term}, ...],
                   x_match :: {String.t(), String.t()}},
              exchange :: Basic.exchange()
            ) :: :ok | {:error, reason :: term}

  defmacro defmessage(message_name, do: body) do
    quote do
      exchange = Module.get_attribute(__MODULE__, :exchange)
      message_alias = Module.concat(__MODULE__, unquote(message_name))

      defmodule message_alias do
        use HomeRabbit.Message, exchange: exchange
        alias __MODULE__

        unquote(body)
      end
    end
  end

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      alias HomeRabbit.ChannelPool
      alias AMQP.{Basic, Queue, Exchange}

      import HomeRabbit.Exchange

      require Logger

      use GenServer

      @behaviour HomeRabbit.Exchange

      @exchange opts[:exchange]
      @exchange_type opts[:exchange_type]
      @queues opts[:queues]
      @errors_queue Keyword.get(opts, :errors_queue, nil)
      @errors_exchange Keyword.get(opts, :errors_exchange, nil)

      @spec publish(message :: HomeRabbit.message()) :: :ok | {:error, reason :: term}
      def publish(routing_key: routing_key, payload: payload, options: options) do
        {:ok, chan} = ChannelPool.get_channel()
        :ok = Basic.publish(chan, @exchange, routing_key, payload, options)
        ChannelPool.release_channel(chan)
      end

      def publish(%{routing_key: routing_key, payload: payload} = message) do
        {:ok, chan} = ChannelPool.get_channel()

        :ok =
          Basic.publish(chan, @exchange, routing_key, payload, message |> Map.get(:options, []))

        ChannelPool.release_channel(chan)
      end

      def start_link(_opts) do
        GenServer.start_link(__MODULE__, nil, name: __MODULE__)
      end

      # Server
      @impl true
      def init(_opts) do
        {:ok, chan} = ChannelPool.get_channel()

        setup_exchange(chan, @queues)

        ChannelPool.release_channel(chan)

        {:ok, nil}
      end

      # Setup

      defp setup_exchange(chan, queues) do
        with :ok <- Exchange.declare(chan, @exchange, @exchange_type, durable: true) do
          Logger.debug(
            "Exchange was declared:\nExchange: #{@exchange}\nType: #{@exchange_type |> inspect()}"
          )

          queues |> Enum.each(&setup_queue(chan, &1, fn -> bind_queue(chan, &1, @exchange) end))
        else
          {:error, reason} ->
            Logger.error("Failed exchange setup:\nExchange: #{@exchange}\nReason: #{reason}")
        end
      end

      defp setup_queue(chan, queue, bind_fn) do
        with queue <- queue |> get_queue(),
             {:ok, _res} <- queue |> declare_queue(chan),
             :ok <- bind_fn.() do
          Logger.debug(
            "Queue was declared and bound to exchange:\nQueue: #{queue}\nExchange: #{@exchange}"
          )
        else
          {:error, reason} ->
            Logger.error("Failed queue setup:\nQueue: #{queue}\nReason: #{reason}")
        end
      end

      defp declare_queue(queue, chan) do
        if queue == @errors_queue or is_nil(@errors_queue) do
          Queue.declare(chan, queue, durable: true)
        else
          Queue.declare(chan, queue,
            durable: true,
            arguments: [
              {"x-dead-letter-exchange", :longstr, @errors_exchange},
              {"x-dead-letter-routing-key", :longstr, @errors_queue}
            ]
          )
        end
      end
    end
  end
end