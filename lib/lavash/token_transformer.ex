defmodule Lavash.TokenTransformer do
  @moduledoc """
  Behaviour for transforming HEEx tokens before they are processed by TagEngine.

  This allows compile-time modification of the parsed template structure,
  enabling injection of attributes into tags and components.

  ## Token Structure

  Tokens from `Phoenix.LiveView.Tokenizer` include:

  - `{:tag, name, attrs, meta}` - HTML elements like `<div>`, `<input>`
  - `{:remote_component, name, attrs, meta}` - Components like `<Foo.bar>`
  - `{:local_component, name, attrs, meta}` - Components like `<.foo>`
  - `{:slot, name, attrs, meta}` - Slots like `<:header>`
  - `{:close, type, name, meta}` - Closing tags
  - `{:text, content, meta}` - Text content
  - `{:expr, marker, content}` - Elixir expressions `{...}`

  Attributes are tuples of `{name, value, meta}` where value is:
  - `{:string, content, meta}` - String literal `"foo"`
  - `{:expr, content, meta}` - Expression `{@foo}`
  - `nil` - Boolean attribute

  ## Example

      defmodule MyTransformer do
        @behaviour Lavash.TokenTransformer

        @impl true
        def transform(tokens, state) do
          Enum.map(tokens, fn
            {:tag, "input", attrs, meta} ->
              # Inject a data attribute
              new_attr = {"data-my-attr", {:string, "value", meta}, meta}
              {:tag, "input", [new_attr | attrs], meta}

            token ->
              token
          end)
        end
      end
  """

  @doc """
  Transforms a list of tokens.

  Receives the finalized token list and the engine state.
  Returns the (possibly modified) token list.

  The state contains:
  - `:file` - The source file path
  - `:caller` - The `Macro.Env` of the calling module
  - `:source` - The original template source string
  - `:tag_handler` - The tag handler module (e.g., `Phoenix.LiveView.HTMLEngine`)
  """
  @callback transform(tokens :: list(), state :: map()) :: list()
end
