if Code.ensure_loaded?(Plug.Conn) do
  defmodule NOne.Plug do
    @moduledoc """
    Plug adapter that treats one HTTP request as a logical NOne operation.
    """

    @behaviour Plug

    import Plug.Conn

    alias NOne.Config

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      config = Config.new(opts)

      if Config.off?(config) do
        conn
      else
        operation = NOne.start(operation_name(conn, opts), config)

        register_before_send(conn, fn conn ->
          report = NOne.finish(operation)
          NOne.enforce!(report, config)
          conn
        end)
      end
    end

    defp operation_name(conn, opts) do
      case Keyword.get(opts, :operation) do
        nil -> "#{conn.method} #{conn.request_path}"
        operation when is_binary(operation) -> operation
        operation when is_atom(operation) -> Atom.to_string(operation)
        operation when is_function(operation, 1) -> operation.(conn)
      end
    end
  end
end
