defmodule DemoWeb.StreamingChatLive do
  @moduledoc """
  ChatGPT-style streaming chat interface, written in lavash.

  ## What this demo does

  Maintains a chat history. The user types a prompt; the assistant
  responds token-by-token, with each token appearing as the
  server pushes a tiny diff. The "thinking" indicator stays on
  until the first chunk arrives; "streaming" stays on through the
  body of the response.

  ## What's interesting about it

  Streaming output is the canonical use case where lavash's
  `optimistic: true` model breaks down. The assistant's response
  arrives from the server — there's no client-side prediction
  possible. So this demo intentionally uses **server-authoritative
  state**: the only optimism is the user's own message appearing
  instantly when they submit (which IS predictable —
  `set :messages, rx(@messages ++ [%{role: "user", ...}])`).

  The streaming part is plain
  `messages do message {:llm_chunk, ...} do ... end end`. Each
  chunk is a server-side state update that the LiveView diff
  pushes to the browser.

  ## State

    * `:messages` — committed list of `%{role, content}` turns
    * `:draft` — the in-progress assistant response (accumulates
      token by token)
    * `:streaming?` — true while a stream is in flight
    * `:conversation_id` — bumps on each submit so late chunks
      from a previous task are ignored
    * `:input` — the user's textarea contents
  """
  use Lavash.LiveView

  alias Demo.FakeLLM

  state :messages, {:array, :map}, default: [], optimistic: true
  state :draft, :string, default: "", optimistic: true
  state :streaming?, :boolean, default: false, optimistic: true
  state :conversation_id, :integer, default: 0, optimistic: true
  state :input, :string, default: "", optimistic: true, setter: true

  # Transient: holds the most recent submission's trimmed prompt
  # so post-cascade `run` can read it after `:input` has been cleared.
  state :pending_prompt, :string, default: ""

  calculate :has_messages?, rx(length(@messages) > 0)
  calculate :input_valid?, rx(String.trim(@input) != "" and not @streaming?)

  actions do
    # Submit the user's prompt. Append to history immediately,
    # bump the conversation id so any stale chunks from a previous
    # turn are filtered out, flip streaming?, kick off the LLM task.
    action :submit do
      # Capture the trimmed input as pending_prompt BEFORE we clear :input.
      # The post-cascade `run` then reads pending_prompt to spawn the LLM
      # task with the correct user content.
      set :pending_prompt, rx(String.trim(@input))
      set :messages, rx(@messages ++ [%{role: "user", content: String.trim(@input)}])
      set :input, ""
      set :streaming?, true
      set :draft, ""
      set :conversation_id, rx(@conversation_id + 1)

      run fn socket ->
        FakeLLM.stream(
          socket.assigns.pending_prompt,
          self(),
          socket.assigns.conversation_id
        )

        socket
      end
    end

    # Cancel mid-stream. We don't track the task pid (a future
    # primitive could), so cancellation is "ignore future chunks
    # for this conversation_id" — bump the id so the chunk handler
    # short-circuits.
    action :cancel do
      set :streaming?, false
      set :draft, ""
      set :conversation_id, rx(@conversation_id + 1)
    end

    # Clear the conversation entirely. Useful for the demo's reset
    # button.
    action :clear do
      set :messages, []
      set :draft, ""
      set :streaming?, false
      set :conversation_id, rx(@conversation_id + 1)
    end
  end

  messages do
    # A streaming token arrived. If the conversation_id matches the
    # current one, append to the draft. Otherwise drop it on the
    # floor — it's from a cancelled or superseded request.
    message {:llm_chunk, conv_id, token}, [:conv_id, :token] do
      run fn socket ->
        if socket.assigns.conversation_id == conv_id do
          Lavash.Socket.put_state(
            socket,
            :draft,
            socket.assigns.draft <> token
          )
        else
          socket
        end
      end
    end

    # End of stream. Commit the draft as a permanent message,
    # clear the streaming flag.
    message {:llm_done, conv_id}, [:conv_id] do
      run fn socket ->
        if socket.assigns.conversation_id == conv_id do
          new_message = %{role: "assistant", content: socket.assigns.draft}

          socket
          |> Lavash.Socket.put_state(:messages, socket.assigns.messages ++ [new_message])
          |> Lavash.Socket.put_state(:draft, "")
          |> Lavash.Socket.put_state(:streaming?, false)
        else
          socket
        end
      end
    end
  end

  template do
    ~H"""
    <div class="max-w-2xl mx-auto p-6 flex flex-col h-screen">
      <header class="flex items-center justify-between pb-4 border-b mb-4">
        <h1 class="text-2xl font-semibold">Streaming chat (fake LLM)</h1>
        <button
          :if={@has_messages?}
          phx-click="clear"
          class="text-sm text-gray-500 hover:text-gray-900"
        >
          Clear
        </button>
      </header>

      <div class="flex-1 overflow-y-auto space-y-4 pb-4" id="message-log">
        <div :if={not @has_messages? and not @streaming?} class="text-gray-400 text-center mt-12">
          Ask me something. Try "hello", "what is lavash?", or "tell me a joke".
        </div>

        <div
          :for={msg <- @messages}
          class={
            if msg.role == "user",
              do: "flex justify-end",
              else: "flex justify-start"
          }
        >
          <div class={[
            "max-w-md px-4 py-2 rounded-lg whitespace-pre-wrap",
            if(msg.role == "user",
              do: "bg-blue-500 text-white",
              else: "bg-gray-100 text-gray-900"
            )
          ]}>
            {msg.content}
          </div>
        </div>

        <%!-- The in-progress assistant turn. Renders only while
              streaming. The body interpolates @draft directly, so
              every token-append diff updates this one node. --%>
        <div :if={@streaming?} class="flex justify-start" id="streaming-turn">
          <div class="max-w-md px-4 py-2 rounded-lg whitespace-pre-wrap bg-gray-100 text-gray-900">
            <span :if={@draft == ""} class="text-gray-400 italic">thinking…</span>
            <span :if={@draft != ""}>{@draft}<span class="animate-pulse">▎</span></span>
          </div>
        </div>
      </div>

      <form phx-submit="submit" class="flex gap-2 pt-4 border-t">
        <input
          type="text"
          name="input"
          value={@input}
          data-lavash-bind="input"
          placeholder={if @streaming?, do: "streaming…", else: "Type a message"}
          disabled={@streaming?}
          autocomplete="off"
          class="flex-1 px-3 py-2 border rounded focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-50"
        />
        <button
          :if={not @streaming?}
          type="submit"
          disabled={not @input_valid?}
          data-lavash-enabled="input_valid?"
          class="px-4 py-2 bg-blue-500 text-white rounded disabled:bg-gray-300"
        >
          Send
        </button>
        <button
          :if={@streaming?}
          type="button"
          phx-click="cancel"
          class="px-4 py-2 bg-red-500 text-white rounded"
        >
          Cancel
        </button>
      </form>
    </div>
    """
  end
end
