defmodule Coordinator.OpenApi do
  @moduledoc """
  OpenAPI 3.0 description of the coordinator's **public** front-door (`Coordinator.ApiRouter`):
  the OpenAI-compatible chat/models endpoints plus `/health`. Served unauthenticated at
  `/openapi.json` (import into Postman: Import → Link → `https://<host>/openapi.json`) and
  rendered for humans at `/docs`.

  The admin console (`/admin/*`, GitHub-OAuth gated) is intentionally **not** documented here —
  this is the surface external API clients use.
  """

  @version "0.1.0"

  @doc "The OpenAPI spec as a plain map (JSON-encoded by the caller). `server_url` is the base
  URL the client reached the coordinator on."
  def spec(server_url) do
    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "hydra coordinator API",
        "version" => @version,
        "description" =>
          "OpenAI-compatible gateway. A client calls `/v1/chat/completions` exactly as it " <>
            "would call OpenAI; the coordinator routes the request to an eligible worker " <>
            "(local model or the worker's own provider) and returns the result. Authenticate " <>
            "with a gateway API key (`Authorization: Bearer <key>`) issued in the admin " <>
            "console — never a provider secret."
      },
      "servers" => [%{"url" => server_url}],
      "security" => [%{"bearerAuth" => []}],
      "tags" => [
        %{"name" => "chat", "description" => "Chat completions"},
        %{"name" => "models", "description" => "Available models"},
        %{"name" => "system", "description" => "Health / meta"}
      ],
      "paths" => paths(),
      "components" => components()
    }
  end

  defp paths do
    %{
      "/health" => %{
        "get" => %{
          "tags" => ["system"],
          "summary" => "Liveness probe",
          "security" => [],
          "responses" => %{
            "200" => %{
              "description" => "OK",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{"status" => %{"type" => "string", "example" => "ok"}}
                  }
                }
              }
            }
          }
        }
      },
      "/v1/models" => %{
        "get" => %{
          "tags" => ["models"],
          "summary" => "List models currently servable by connected workers",
          "responses" => %{
            "200" => %{
              "description" => "Model list",
              "content" => %{
                "application/json" => %{"schema" => ref("ModelList")}
              }
            },
            "401" => unauthorized()
          }
        }
      },
      "/v1/models/{id}" => %{
        "get" => %{
          "tags" => ["models"],
          "summary" => "Retrieve one model by id",
          "parameters" => [
            %{
              "name" => "id",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"},
              "example" => "qwen3.6-35b-a3b"
            }
          ],
          "responses" => %{
            "200" => %{
              "description" => "Model",
              "content" => %{"application/json" => %{"schema" => ref("Model")}}
            },
            "401" => unauthorized(),
            "404" => error_response("Model not found")
          }
        }
      },
      "/v1/chat/completions" => %{
        "post" => %{
          "tags" => ["chat"],
          "summary" => "Create a chat completion",
          "description" =>
            "Set `stream: true` to receive an OpenAI `chat.completion.chunk` SSE stream " <>
              "(`text/event-stream`, terminated by `data: [DONE]`); otherwise a single JSON " <>
              "`chat.completion`. The request blocks until a worker returns the result or the " <>
              "timeout elapses.",
          "parameters" => [
            %{
              "name" => "x-hydra-timeout-ms",
              "in" => "header",
              "required" => false,
              "description" => "Override the per-request wait (ms). Also settable via the " <>
                "`timeout_ms` body field. Capped at 600000.",
              "schema" => %{"type" => "integer"}
            }
          ],
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{"schema" => ref("ChatCompletionRequest")}
            }
          },
          "responses" => %{
            "200" => %{
              "description" => "Completion (JSON) or SSE stream when `stream: true`",
              "content" => %{
                "application/json" => %{"schema" => ref("ChatCompletion")},
                "text/event-stream" => %{
                  "schema" => %{
                    "type" => "string",
                    "description" => "A sequence of `data: {chat.completion.chunk}` events " <>
                      "ending with `data: [DONE]`."
                  }
                }
              }
            },
            "400" => error_response("Invalid request (e.g. empty `messages`)"),
            "401" => unauthorized(),
            "429" => error_response("Upstream provider rate limit"),
            "502" => error_response("Worker or upstream provider error"),
            "504" => error_response("No worker completed the job in time")
          }
        }
      }
    }
  end

  defp components do
    %{
      "securitySchemes" => %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "description" => "Gateway API key (`hydra_sk_…`) issued in the admin console."
        }
      },
      "schemas" => %{
        "Message" => %{
          "type" => "object",
          "required" => ["role"],
          "properties" => %{
            "role" => %{"type" => "string", "enum" => ["system", "user", "assistant", "tool"]},
            "content" => %{"type" => "string", "nullable" => true},
            "tool_calls" => %{
              "type" => "array",
              "items" => ref("ToolCall"),
              "description" => "Present on assistant messages that requested tool calls."
            },
            "tool_call_id" => %{
              "type" => "string",
              "description" => "On `role: tool` messages: id of the call this result answers."
            }
          }
        },
        "ToolCall" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "type" => %{"type" => "string", "example" => "function"},
            "function" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "arguments" => %{
                  "type" => "string",
                  "description" => "JSON-encoded arguments object."
                }
              }
            }
          }
        },
        "ChatCompletionRequest" => %{
          "type" => "object",
          "required" => ["messages"],
          "properties" => %{
            "model" => %{
              "type" => "string",
              "description" => "Model id (see `/v1/models`). Routed to a worker serving it.",
              "example" => "qwen3.6-35b-a3b"
            },
            "messages" => %{"type" => "array", "items" => ref("Message"), "minItems" => 1},
            "max_tokens" => %{"type" => "integer"},
            "temperature" => %{"type" => "number"},
            "tools" => %{
              "type" => "array",
              "description" =>
                "OpenAI-shaped tool definitions (`{type: \"function\", function: {name, description, parameters}}`), forwarded to the worker's backend.",
              "items" => %{"type" => "object"}
            },
            "tool_choice" => %{
              "description" => "`auto` | `none` | `required` | `{type: \"function\", function: {name}}`."
            },
            "stream" => %{"type" => "boolean", "default" => false},
            "timeout_ms" => %{"type" => "integer", "description" => "Per-request wait (ms)."}
          },
          "example" => %{
            "model" => "qwen3.6-35b-a3b",
            "messages" => [%{"role" => "user", "content" => "Say hello in one word."}],
            "max_tokens" => 64
          }
        },
        "ChatCompletion" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "object" => %{"type" => "string", "example" => "chat.completion"},
            "created" => %{"type" => "integer"},
            "model" => %{"type" => "string"},
            "choices" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "index" => %{"type" => "integer"},
                  "message" => ref("Message"),
                  "finish_reason" => %{
                    "type" => "string",
                    "enum" => ["stop", "tool_calls"],
                    "example" => "stop"
                  }
                }
              }
            },
            "usage" => %{
              "type" => "object",
              "properties" => %{
                "prompt_tokens" => %{"type" => "integer"},
                "completion_tokens" => %{"type" => "integer"},
                "total_tokens" => %{"type" => "integer"}
              }
            }
          }
        },
        "Model" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "object" => %{"type" => "string", "example" => "model"},
            "created" => %{"type" => "integer"},
            "owned_by" => %{"type" => "string"}
          }
        },
        "ModelList" => %{
          "type" => "object",
          "properties" => %{
            "object" => %{"type" => "string", "example" => "list"},
            "data" => %{"type" => "array", "items" => ref("Model")}
          }
        },
        "Error" => %{
          "type" => "object",
          "properties" => %{
            "error" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string"},
                "type" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end

  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  defp unauthorized, do: error_response("Missing or invalid API key")

  defp error_response(desc) do
    %{
      "description" => desc,
      "content" => %{"application/json" => %{"schema" => ref("Error")}}
    }
  end

  @doc "A minimal HTML page that renders the spec with Redoc (loaded from a CDN)."
  def docs_html do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>hydra coordinator API</title>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <style>body { margin: 0; }</style>
    </head>
    <body>
      <redoc spec-url="/openapi.json"></redoc>
      <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
    </body>
    </html>
    """
  end
end
