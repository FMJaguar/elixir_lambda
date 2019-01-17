defmodule LambdaRuntime do
  @moduledoc """
  Read Lambda request, process, return, repeat.

  This module provides a simple loop that handles
  Lambda requests.

  Documentation on the Lambda interface can be found at
  https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html.
  """

  @content_type_json 'application/json'

  def run(httpc \\ :httpc) do
    Application.ensure_all_started(:inets)

    lambda_runtime_api = System.get_env("AWS_LAMBDA_RUNTIME_API")
    handler_name = System.get_env("_HANDLER")
    base_url = "http://#{lambda_runtime_api}/2018-06-01" |> String.to_charlist()

    backend = fn
      :get, url_path, _, _ ->
        httpc.request(:get, {base_url ++ url_path, []}, [], [])

      :post, url_path, content_type, body ->
        httpc.request(:post, {base_url ++ url_path, [], content_type, body}, [], [])
    end

    if Regex.match?(~r"^[A-Z:][A-Za-z0-9_.]+$", handler_name) do
      # TODO: check prerequisites. else report to '/runtime/init/error' and quit
      {handler, _} = Code.eval_string("&#{handler_name}/2")

      loop(backend, handler)
    else
      send_init_error(
        backend,
        "Invalid handler signature: #{handler_name}. Expected something like \"Module.function\"."
      )
    end
  end

  def loop(backend, handler) do
    handle(backend, handler)
    loop(backend, handler)
  end

  def handle(backend, handler) do
    backend.(:get, '/runtime/invocation/next', nil, nil)
    |> parse_request()
    |> (fn {event, context, request_id} -> {handler.(event, context), request_id} end).()
    |> handle_response(backend)
  end

  defp parse_request({:ok, {{'HTTP/1.1', 200, 'OK'}, headers, body}}) do
    headers = Map.new(headers)
    content_type = Map.get(headers, 'content-type')
    request_id = Map.get(headers, 'lambda-runtime-aws-request-id')

    event =
      case content_type do
        @content_type_json -> Jason.decode!(body)
        _ -> body
      end

    context = %{
      :content_type => content_type,
      :request_id => request_id,
      :deadline => Map.get(headers, 'lambda-runtime-deadline-ms'),
      :function_arn => Map.get(headers, 'lambda-runtime-invoked-function-arn'),
      :trace_id => Map.get(headers, 'lambda-runtime-trace-id'),
      :client_context => Map.get(headers, 'lambda-runtime-client-context'),
      :cognito_identity => Map.get(headers, 'lambda-runtime-cognito-identity')
    }

    {event, context, request_id}
  end

  defp parse_request(maybe_error) do
    IO.puts("Error while requesting Lambda request: #{inspect(maybe_error)}. So long!")
  end

  defp handle_response({{:ok, response}, request_id}, backend)
       when is_map(response) or is_list(response) do
    {:ok, response} = Jason.encode(response)
    send_response(backend, request_id, @content_type_json, response)
  end

  defp handle_response({{:ok, response}, request_id}, backend) when is_binary(response) do
    send_response(backend, request_id, 'text/plain', response)
  end

  defp handle_response({{:ok, response}, request_id}, backend) do
    send_response(backend, request_id, 'application/octet-stream', Kernel.inspect(response))
  end

  defp handle_response({{:ok, content_type, response}, request_id}, backend)
       when is_binary(response) do
    send_response(backend, request_id, content_type, response)
  end

  defp handle_response({{:ok, content_type, response}, request_id}, backend) do
    send_response(backend, request_id, content_type, Kernel.inspect(response))
  end

  defp handle_response({{:error, message}, request_id}, backend) do
    send_error(backend, request_id, message)
  end

  defp handle_response({what_else, request_id}, backend) do
    send_error(backend, request_id, Kernel.inspect(what_else))
  end

  defp send_response(backend, request_id, content_type, body) do
    url = '/runtime/invocation/' ++ request_id ++ '/response'
    backend.(:post, url, content_type, body)
  end

  defp send_error(backend, request_id, message) do
    url = '/runtime/invocation/' ++ request_id ++ '/error'

    body =
      Jason.encode!(%{
        "errorMessage" => message,
        "errorType" => "RuntimeException"
      })

    backend.(:post, url, @content_type_json, body)
  end

  defp send_init_error(backend, message) do
    url = '/runtime/init/error'

    body =
      Jason.encode!(%{
        "errorMessage" => message,
        "errorType" => "InitializationError"
      })

    backend.(:post, url, @content_type_json, body)
  end
end
