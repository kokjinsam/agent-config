defmodule EctoIsolator.Adapters.Req do
  @moduledoc """
  Req request-step adapter.

  Attach it to a request with:

      Req.new() |> EctoIsolator.Adapters.Req.attach()
  """

  @adapter :req

  def attach(request, opts \\ []) do
    req_request = req_request_module()

    request
    |> then(&apply(req_request, :register_options, [&1, [:ecto_isolator]]))
    |> then(&apply(req_request, :merge_options, [&1, opts]))
    |> then(
      &apply(req_request, :prepend_request_steps, [
        &1,
        [ecto_isolator: {__MODULE__, :request_step, []}]
      ])
    )
  end

  def request_step(request) do
    unless option(request, :ecto_isolator) == false do
      EctoIsolator.check!(@adapter, :request, details: request_details(request))
    end

    request
  end

  defp request_details(request) do
    %{
      method: field(request, :method),
      url: format_url(field(request, :url))
    }
  end

  defp option(request, key) do
    options = field(request, :options) || %{}

    cond do
      is_map(options) -> Map.get(options, key)
      Keyword.keyword?(options) -> Keyword.get(options, key)
      true -> nil
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp format_url(%URI{} = uri), do: URI.to_string(uri)
  defp format_url(url) when is_binary(url), do: url
  defp format_url(nil), do: nil
  defp format_url(url), do: inspect(url)

  defp req_request_module, do: Req.Request
end
