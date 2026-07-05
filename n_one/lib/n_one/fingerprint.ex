defmodule NOne.Fingerprint do
  @moduledoc false

  @number_pattern ~r/\b\d+(?:\.\d+)?\b/
  @postgres_placeholder_pattern ~r/\$\d+/
  @single_quoted_pattern ~r/'(?:''|[^'])*'/
  @whitespace_pattern ~r/\s+/

  def query(query) when is_binary(query) do
    query
    |> String.replace(@single_quoted_pattern, "?")
    |> String.replace(@postgres_placeholder_pattern, "?")
    |> String.replace(@number_pattern, "?")
    |> String.replace(@whitespace_pattern, " ")
    |> String.trim()
  end

  def query(other), do: inspect(other)

  def command(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      nil -> nil
      "" -> nil
      command -> String.upcase(command)
    end
  end

  def command(_other), do: nil

  def params_hash(params), do: :erlang.phash2(params || [])
end
