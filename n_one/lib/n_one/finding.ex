defmodule NOne.Finding do
  @moduledoc """
  A repeated query fingerprint detected inside one logical operation.
  """

  @enforce_keys [:count, :fingerprint, :unique_param_sets]
  defstruct [:source, :command, :fingerprint, :count, :unique_param_sets]
end
