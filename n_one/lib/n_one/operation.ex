defmodule NOne.Operation do
  @moduledoc false

  defstruct [:operation, :owner_pid, :handler_id, :collector, :config]
end
