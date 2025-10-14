# TeslaDedup

[![Hex.pm](https://img.shields.io/hexpm/v/tesla_dedup.svg)](https://hex.pm/packages/tesla_dedup)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/tesla_dedup/)

**Tesla middleware for request deduplication** - Prevents concurrent identical requests from causing duplicate side effects (double charges, duplicate orders, race conditions).

## What is Request Deduplication?

Request deduplication is a **concurrency coordination pattern** that prevents multiple identical HTTP requests from executing simultaneously. When duplicate requests arrive, only the first executes - the rest wait and receive the same response.

### ⚠️ Important: This is NOT Caching

Deduplication is **orthogonal to caching**:

- **Deduplication**: Prevents _concurrent_ duplicates during request execution (milliseconds to seconds)
- **Caching**: Stores responses for reuse over time (minutes to hours)

```elixir
# Deduplication: Only concurrent requests are shared
# Timeline: [Request 1 starts] -> [Duplicate waits] -> [Both get response] -> [Done]
#           |------------------500ms-------------------|

# Caching: Responses stored for future use
# Timeline: [Request 1] -> [Response cached for 5min] -> [Later request uses cache]
```

## Use Cases

- **Payment Processing**: Prevent double charges from double-clicks or retry storms
- **Order Creation**: Ensure idempotency for POST/PUT operations
- **Critical Mutations**: Prevent duplicate side effects in distributed systems
- **API Rate Limiting**: Reduce duplicate requests that would count against rate limits

## Installation

Add `tesla_dedup` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:tesla, "~> 1.4"},
    {:tesla_dedup, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Basic Usage

```elixir
defmodule MyClient do
  use Tesla

  # Add deduplication middleware
  plug Tesla.Middleware.Dedup

  # Other middleware
  plug Tesla.Middleware.JSON
  plug Tesla.Adapter.Hackney
end

# If these requests happen concurrently, only one executes
# The second request waits and receives the same response
Task.async(fn -> MyClient.post("/charge", %{amount: 100}) end)
Task.async(fn -> MyClient.post("/charge", %{amount: 100}) end)
```

### With Custom Key Function

By default, deduplication uses `method + URL + body`. Customize this:

```elixir
defmodule PaymentClient do
  use Tesla

  # Deduplicate by URL only (ignore body differences)
  plug Tesla.Middleware.Dedup,
    key_fn: fn env -> env.url end

  plug Tesla.Adapter.Hackney
end
```

## How It Works

### Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Request 1  │  │  Request 2  │  │  Request 3  │
│  (identical)│  │  (identical)│  │  (identical)│
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       └────────────────┼────────────────┘
                        ▼
            ┌────────────────────────┐
            │ Tesla.Middleware.Dedup │
            └───────────┬────────────┘
                        │
            ┌───────────▼────────────┐
            │ Hash: method+url+body  │
            └───────────┬────────────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
    [Execute]      [Wait for]     [Wait for]
         │          Response       Response
         ▼              │              │
    ┌─────────┐         │              │
    │ Adapter │         │              │
    └────┬────┘         │              │
         │              │              │
    [Response]──────────┴──────────────┘
         │
         └──────────> All get same response
```

### States

1. **`:execute`** - First request executes normally
2. **`:wait`** - Duplicate requests wait for response (blocking in middleware)
3. **`:completed`** - Brief window (500ms) to catch race conditions

## Configuration

### Options

| Option    | Type                   | Default | Description                                   |
| --------- | ---------------------- | ------- | --------------------------------------------- |
| `:key_fn` | `(Tesla.Env -> any())` | `nil`   | Custom function to generate deduplication key |

### Custom Key Examples

```elixir
# Include headers in deduplication key
plug Tesla.Middleware.Dedup,
  key_fn: fn env ->
    {env.method, env.url, env.body, env.headers}
  end

# Use custom business logic
plug Tesla.Middleware.Dedup,
  key_fn: fn env ->
    # Extract idempotency key from headers
    idempotency_key = get_header(env, "idempotency-key")
    {env.url, idempotency_key}
  end
```

## Telemetry

The middleware emits telemetry events:

- **`[:tesla_dedup, :execute]`** - First request, will execute
- **`[:tesla_dedup, :wait]`** - Duplicate request, waiting
- **`[:tesla_dedup, :cache_hit]`** - Request completed recently

### Example

```elixir
:telemetry.attach_many(
  "dedup-handler",
  [
    [:tesla_dedup, :execute],
    [:tesla_dedup, :wait],
    [:tesla_dedup, :cache_hit]
  ],
  fn event, _measurements, metadata, _config ->
    Logger.info("Dedup: #{inspect(event)}, key: #{metadata.dedup_key}")
  end,
  nil
)
```

## Middleware Ordering

Place `Tesla.Middleware.Dedup` **early** in your middleware stack:

```elixir
defmodule MyClient do
  use Tesla

  # ✅ GOOD: Dedup first
  plug Tesla.Middleware.Dedup
  plug Tesla.Middleware.RateLimit
  plug Tesla.Middleware.CircuitBreaker
  plug Tesla.Middleware.JSON
  plug Tesla.Adapter.Hackney
end
```

## Testing

Use `Tesla.Mock` for testing:

```elixir
defmodule MyClientTest do
  use ExUnit.Case

  test "prevents duplicate charges" do
    Tesla.Mock.mock(fn env ->
      Process.sleep(100)
      {:ok, %{env | status: 201, body: %{charge_id: "ch_123"}}}
    end)

    tasks = [
      Task.async(fn -> MyClient.charge(100) end),
      Task.async(fn -> MyClient.charge(100) end)
    ]

    results = Task.await_many(tasks)

    # Both get same successful response
    assert Enum.all?(results, fn {:ok, env} ->
      env.status == 201 && env.body.charge_id == "ch_123"
    end)
  end
end
```

## Documentation

Full documentation available at [https://hexdocs.pm/tesla_dedup](https://hexdocs.pm/tesla_dedup)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

Inspired by the deduplication middleware in [HTTPower](https://github.com/marceloboeira/httpower).
