require Logger

defmodule BitcoinStream.Server do
  use Application

  def start(_type, _args) do
    { socket_port, "" } = Integer.parse(System.get_env("PORT"));
    { zmq_tx_port, "" } = Integer.parse(System.get_env("BITCOIN_ZMQ_RAWTX_PORT"));
    { zmq_block_port, "" } = Integer.parse(System.get_env("BITCOIN_ZMQ_RAWBLOCK_PORT"));
    { zmq_sequence_port, "" } = Integer.parse(System.get_env("BITCOIN_ZMQ_SEQUENCE_PORT"));
    { rpc_port, "" } = Integer.parse(System.get_env("BITCOIN_RPC_PORT"));
    { rpc_pools, "" } = Integer.parse(System.get_env("RPC_POOLS"));
    { rpc_pool_size, "" } = Integer.parse(System.get_env("RPC_POOL_SIZE"));
    log_level = System.get_env("LOG_LEVEL");
    btc_host = System.get_env("BITCOIN_HOST");

    case log_level do
      "debug" ->
        Logger.configure(level: :debug);

      "error" ->
        Logger.configure(level: :error);

      _ ->
        Logger.configure(level: :info);
    end

    children = [
      Registry.child_spec(
        keys: :duplicate,
        name: Registry.BitcoinStream
      ),
      {Finch,
       name: FinchClient,
       pools: %{
         :default => [size: rpc_pool_size, count: rpc_pools],
         "http://#{btc_host}:#{rpc_port}" => [size: rpc_pool_size, count: rpc_pools]
       }},
      { BitcoinStream.RPC, [host: btc_host, port: rpc_port, name: :rpc] },
      { BitcoinStream.BlockData, [name: :block_data] },
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: BitcoinStream.Router,
        options: [
          dispatch: dispatch(),
          port: socket_port
        ]
      ),
      %{
        id: BitcoinStream.Bridge,
        start: {Supervisor, :start_link, [
          [
            { BitcoinStream.Mempool, [name: :mempool] },
            { BitcoinStream.Mempool.Sync, [name: :mempool_sync] },
            BitcoinStream.Bridge.Tx.child_spec(host: btc_host, port: zmq_tx_port),
            BitcoinStream.Bridge.Block.child_spec(host: btc_host, port: zmq_block_port),
            BitcoinStream.Bridge.Sequence.child_spec(host: btc_host, port: zmq_sequence_port),
          ],
          [strategy: :one_for_all]
        ]},
        type: :supervisor,
        restart: :permanent
      }
    ]

    opts = [strategy: :one_for_one, name: BitcoinStream.Application]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    [
      {:_,
        [
          {"/ws/txs", BitcoinStream.SocketHandler, []},
          {:_, Plug.Cowboy.Handler, {BitcoinStream.Router, []}}
        ]
      }
    ]
  end
end
