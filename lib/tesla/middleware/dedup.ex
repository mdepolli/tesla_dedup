defmodule Tesla.Middleware.Dedup do
  @moduledoc """
  Tesla middleware for in-flight request deduplication.

  Prevents concurrent identical requests from causing duplicate side effects
  (e.g., double charges, duplicate orders) by tracking in-flight requests and
  sharing responses with identical concurrent requests.

  **Important**: This is NOT caching - it only deduplicates concurrent requests.
  Completed requests are tracked briefly (500ms) to catch race conditions, not
  for performance optimization.

  ## How It Works

  1. **Request Fingerprinting** - Each request gets a hash based on method + URL + body
  2. **In-Flight Tracking** - First request executes normally, subsequent identical requests wait
  3. **Response Sharing** - When the first request completes, all waiting requests receive the same response
  4. **Automatic Cleanup** - Tracking data is automatically removed after brief TTL

  ## Use Cases

  - Prevent double charges from double-clicks on payment buttons
  - Prevent duplicate orders from retry storms or race conditions
  - Ensure idempotency for critical mutations (POST/PUT/DELETE)

  ## Usage

      defmodule MyClient do
        use Tesla

        # Simple usage - deduplicate all requests
        plug Tesla.Middleware.Dedup

        # With options
        plug Tesla.Middleware.Dedup,
          key_fn: &custom_key_function/1

        plug Tesla.Adapter.Hackney
      end

  ## Configuration Options

  - `:key_fn` - Custom function to generate deduplication key from `Tesla.Env`.
    Default: hashes method + URL + body

  ## Example: Custom Key Function

      # Only deduplicate based on URL (ignore method/body differences)
      plug Tesla.Middleware.Dedup,
        key_fn: fn env -> env.url end

      # Include headers in deduplication key
      plug Tesla.Middleware.Dedup,
        key_fn: fn env ->
          {env.method, env.url, env.body, env.headers}
        end

  ## Telemetry Events

  This middleware emits telemetry events for monitoring:

  - `[:tesla_dedup, :execute]` - First request, will execute
  - `[:tesla_dedup, :wait]` - Duplicate request, waiting for response
  - `[:tesla_dedup, :cache_hit]` - Request completed recently, returning cached result

  ### Event Metadata

  All events include:
  - `:dedup_key` - The deduplication hash
  - `:method` - HTTP method
  - `:url` - Request URL

  ## Middleware Ordering

  Place this middleware EARLY in your stack, before rate limiters or circuit breakers,
  so duplicate requests don't consume rate limit tokens or affect circuit breaker state.

      defmodule MyClient do
        use Tesla

        plug Tesla.Middleware.Dedup       # ← Early: dedupe first
        plug Tesla.Middleware.RateLimit
        plug Tesla.Middleware.CircuitBreaker
        plug Tesla.Middleware.JSON
        plug Tesla.Adapter.Hackney
      end
  """

  @behaviour Tesla.Middleware

  require Logger

  @impl Tesla.Middleware
  def call(env, next, opts) do
    dedup_key = generate_key(env, opts)

    case TeslaDedup.Server.deduplicate(dedup_key) do
      {:ok, :execute} ->
        # First occurrence - execute the request
        :telemetry.execute(
          [:tesla_dedup, :execute],
          %{},
          %{
            dedup_key: dedup_key,
            method: env.method,
            url: env.url
          }
        )

        # Execute request through remaining middleware
        result =
          case Tesla.run(env, next) do
            {:ok, _env} = success -> success
            {:error, _reason} = error -> error
          end

        # Share result with waiting requests
        TeslaDedup.Server.complete(dedup_key, result)

        result

      {:ok, :wait, ref} ->
        # Duplicate in-flight - wait for the first request to complete
        :telemetry.execute(
          [:tesla_dedup, :wait],
          %{},
          %{
            dedup_key: dedup_key,
            method: env.method,
            url: env.url
          }
        )

        receive do
          {:dedup_response, ^ref, result} ->
            result
        after
          30_000 ->
            {:error, :dedup_timeout}
        end

      {:ok, result} ->
        # Request completed recently - return cached result
        :telemetry.execute(
          [:tesla_dedup, :cache_hit],
          %{},
          %{
            dedup_key: dedup_key,
            method: env.method,
            url: env.url
          }
        )

        result
    end
  end

  # Private Functions

  defp generate_key(env, opts) do
    case Keyword.get(opts, :key_fn) do
      nil ->
        # Default: hash method + url + body
        url = env.url |> to_string()
        body = body_to_string(env.body)
        TeslaDedup.Server.hash(env.method, url, body)

      key_fn when is_function(key_fn, 1) ->
        # Custom key function
        key_fn.(env)
        |> to_string()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    end
  end

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_to_string(nil), do: ""
  defp body_to_string(body), do: inspect(body)
end
