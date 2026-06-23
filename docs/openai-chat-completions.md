# OpenAI Chat Completions API Reference

> Source: https://developers.openai.com/api/reference/chat-completions/overview

## Overview

The Chat Completions API endpoint generates a model response from a list of messages comprising a conversation.

**Endpoint:** `POST /v1/chat/completions`

## Authentication

```
Authorization: Bearer OPENAI_API_KEY
```

With organization/project headers (optional):
```
OpenAI-Organization: $ORGANIZATION_ID
OpenAI-Project: $PROJECT_ID
```

## Request Body

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | Model ID (e.g., `gpt-4o-mini`, `gpt-4o`) |
| `messages` | array | Yes | Array of message objects |
| `temperature` | number | No | Sampling temperature (0-2). Default: 1 |
| `max_tokens` | integer | No | Maximum tokens to generate |
| `stream` | boolean | No | Enable streaming. Default: false |
| `stop` | string/array | No | Stop sequences |
| `frequency_penalty` | number | No | -2.0 to 2.0 |
| `presence_penalty` | number | No | -2.0 to 2.0 |
| `top_p` | number | No | Nucleus sampling (0-1). Default: 1 |

## Message Object

```json
{
  "role": "system" | "user" | "assistant" | "tool",
  "content": "string or array of content parts"
}
```

### Role Types
- **system**: Developer-provided instructions the model follows
- **user**: User input/messages
- **assistant**: Model's responses (for multi-turn)
- **tool**: Tool/function call results

### Content Part Types (for array content)
- `{"type": "text", "text": "..."}`
- `{"type": "image_url", "image_url": {"url": "...", "detail": "auto|low|high"}}`
- `{"type": "input_audio", "input_audio": {"data": "...", "format": "wav|mp3"}}`
- `{"type": "file", "file": {"file_data": "...", "file_id": "...", "filename": "..."}}`

## Response Object

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1234567890,
  "model": "gpt-4o-mini",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "response text"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 100,
    "completion_tokens": 50,
    "total_tokens": 150
  }
}
```

### finish_reason Values
- `"stop"` — Natural stop point or stop sequence hit
- `"length"` — max_tokens reached
- `"tool_calls"` — Model called a tool/function
- `"content_filter"` — Content filtered
- `"function_call"` — Deprecated, replaced by tool_calls

## Function Calling

```json
{
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string"}
          },
          "required": ["location"]
        }
      }
    }
  ]
}
```

Model responds with:
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "tool_calls": [{
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "get_weather",
          "arguments": "{\"location\": \"Paris\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

## Streaming

Set `"stream": true` to receive Server-Sent Events (SSE):

```
data: {"id":"...","choices":[{"delta":{"content":"Hello"},"index":0}]}
data: {"id":"...","choices":[{"delta":{"content":" world"},"index":0}]}
data: [DONE]
```

Each chunk is a `ChatCompletionChunk` with `delta` instead of `message`.

## Error Responses

```json
{
  "error": {
    "message": "Invalid API key",
    "type": "invalid_request_error",
    "param": null,
    "code": "invalid_api_key"
  }
}
```

## Rate Limits

Response headers include:
- `x-ratelimit-limit-requests`
- `x-ratelimit-limit-tokens`
- `x-ratelimit-remaining-requests`
- `x-ratelimit-remaining-tokens`
- `x-ratelimit-reset-requests`
- `x-ratelimit-reset-tokens`

## Debugging

- `x-request-id`: Unique request ID for troubleshooting
- `X-Client-Request-Id`: Your own request ID (max 512 ASCII chars)
- `openai-processing-ms`: Time taken processing the request
