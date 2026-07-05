defmodule EctoIsolator.TestRepo do
  def in_transaction? do
    Process.get(:ecto_isolator_test_transaction, false)
  end

  def transact(fun) when is_function(fun, 0) do
    previous = Process.get(:ecto_isolator_test_transaction)
    Process.put(:ecto_isolator_test_transaction, true)

    try do
      fun.()
    after
      if previous == nil do
        Process.delete(:ecto_isolator_test_transaction)
      else
        Process.put(:ecto_isolator_test_transaction, previous)
      end
    end
  end
end

defmodule EctoIsolator.RaisingRepo do
  def in_transaction? do
    raise "repo unavailable"
  end
end
