defmodule Demo.FakeLLM do
  @moduledoc """
  Deterministic fake LLM that emits tokens with simulated latency,
  for the streaming chat demo.

  Real-world streaming chat uses an OpenAI-style HTTP stream or a
  websocket to the model provider. For a demo we want something
  that:

    * Works offline (no API keys, no network)
    * Is deterministic (the same prompt gives the same answer, so
      e2e tests can assert on the rendered output)
    * Streams at human-readable pace (~30-80ms per token) so the
      animation is visible

  ## Usage

      Demo.FakeLLM.stream(prompt, dest_pid)

  Emits `{:llm_chunk, conversation_id, token}` to `dest_pid` for
  each token, then `{:llm_done, conversation_id}` when the
  response is complete. `conversation_id` lets the LV correlate
  chunks with the message they belong to (so a rapid second prompt
  doesn't get tokens from the first response).

  The task is unsupervised — the LV is responsible for tracking
  the task pid if it wants to cancel mid-stream.
  """

  @doc """
  Start streaming a response for `prompt` to `dest_pid`. Returns
  the task pid (so the caller can `Process.exit/2` to cancel).
  """
  def stream(prompt, dest_pid, conversation_id) do
    Task.start(fn ->
      response = generate_response(prompt)
      tokens = tokenize(response)

      Enum.each(tokens, fn token ->
        Process.sleep(token_delay())
        send(dest_pid, {:llm_chunk, conversation_id, token})
      end)

      send(dest_pid, {:llm_done, conversation_id})
    end)
  end

  # Canned responses — keyed by lowercase keyword match so the demo
  # has a few different stories to tell.
  defp generate_response(prompt) do
    lower = String.downcase(prompt)

    cond do
      lower =~ "hello" or lower =~ "hi" ->
        "Hello! I'm a fake LLM running entirely server-side. " <>
          "Try asking me about Phoenix LiveView, lavash, or streaming."

      lower =~ "liveview" or lower =~ "phoenix" ->
        "Phoenix LiveView lets you build interactive web UIs in Elixir " <>
          "without writing JavaScript. The server holds the state; the " <>
          "browser holds a thin diff-applier. When state changes, " <>
          "LiveView computes the smallest possible patch and pushes it " <>
          "down the WebSocket."

      lower =~ "lavash" ->
        "Lavash is a Spark DSL that lets you describe LiveView modules " <>
          "declaratively. Instead of writing handle_event/3 by hand, you " <>
          "declare actions; instead of mutating socket.assigns, you " <>
          "declare state fields. The optimistic UI layer runs a copy of " <>
          "the reactive graph in the browser so changes feel instant."

      lower =~ "stream" ->
        "Streaming is interesting because it forces the server to push " <>
          "many small updates instead of one big response. In Phoenix " <>
          "LiveView the natural shape is start_async paired with " <>
          "send(self(), {:chunk, token}) inside the task body. The " <>
          "message handler appends each chunk to an assign; the LV diff " <>
          "machinery sends just the new tail to the browser."

      lower =~ "joke" ->
        "Why do Elixir programmers prefer recursion? Because the " <>
          "alternative is shouting at the void with no base case."

      lower =~ "elixir" ->
        "Elixir is a functional language built on the Erlang VM. Its " <>
          "killer feature is fault tolerance: processes are cheap, " <>
          "supervisors restart things that crash, and 'let it crash' " <>
          "is a design philosophy rather than an apology."

      true ->
        "That's an interesting question. I'm a deterministic fake LLM " <>
          "with only a handful of canned responses, so my answer to most " <>
          "things is to politely redirect: try asking me about LiveView, " <>
          "lavash, streaming, or Elixir."
    end
  end

  # Naive whitespace-preserving tokenizer. Real LLMs use BPE or
  # similar, emitting subword chunks. Splitting on word boundaries
  # is close enough that the visual effect (incremental fill) is
  # the same.
  defp tokenize(text) do
    text
    |> String.split(~r/(\s+)/, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
  end

  # Token delay in ms. Randomized in a narrow band so the stream
  # doesn't feel mechanical. Set LAVASH_LLM_DELAY env to override
  # (useful for e2e tests that want speed).
  defp token_delay do
    base =
      case System.get_env("LAVASH_LLM_DELAY") do
        nil -> 40
        s -> String.to_integer(s)
      end

    base + :rand.uniform(20)
  end
end
