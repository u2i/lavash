# Streaming chat demo: what worked, what strained, what we'd want

This doc is a hands-on review of building a ChatGPT-style streaming
chat interface in lavash today. The demo at
`demo/lib/demo_web/live/streaming_chat_live.ex` is real working
code; this is the thinking around it.

## The shape we built

A LiveView that:

1. Holds chat history as `state :messages, {:array, :map}`.
2. Submits a prompt — appends user message immediately (optimistic),
   kicks off a fake LLM task via `Task.start(fn -> ... end)` that
   sends `{:llm_chunk, conv_id, token}` messages back to `self()`.
3. A `messages do message {:llm_chunk, ...} do ... end end` clause
   appends each token to `state :draft, :string`.
4. On `{:llm_done, conv_id}`, commits the draft as an assistant
   message in the history and clears the draft.
5. Uses a `conversation_id` counter to ignore late chunks from
   cancelled or superseded requests.

It works. The user sees their message appear instantly, then the
"thinking…" placeholder, then the assistant's response filling
in token by token, then the committed reply joining the
scrollback.

But the path to "it works" went through several places where the
DSL doesn't quite fit, and a few escape hatches into raw
`Lavash.Socket.put_state/3`. Those are the interesting bits.

---

## Things lavash expressed well

### Optimistic user message

The instant-feedback feel of "type → submit → your message
appears" is exactly what `optimistic: true` is for. The client
already knows what the user typed; appending it to the messages
array client-side doesn't need a roundtrip.

```elixir
action :submit do
  set :messages, rx(@messages ++ [%{role: "user", content: String.trim(@input)}])
  set :input, ""
  set :streaming?, true
  ...
end
```

The optimistic JS transpiler handles `++` on arrays, the merge
walker preserves DOM identity for unchanged messages, and the
new message lands without flicker. This is lavash at its best.

### Decoupling the "what" from the "when"

`messages do message {:llm_chunk, ...} do ... end end` is the
right shape. The message handler doesn't care that the LLM task
spawned the messages — it just declaratively reacts to
`{:llm_chunk, conv_id, token}`. If we later swap the fake LLM
for a real one, the message clause is unchanged.

### `calculate :input_valid?`

`rx(String.trim(@input) != "" and not @streaming?)` reactively
disables the submit button. Bound via `data-lavash-enabled` so
the button toggles client-side as the user types. No round trip
for "is the input empty?" feedback.

---

## Where lavash strained

### 1. Token append is per-chunk state mutation

The `:llm_chunk` handler has to:

```elixir
run fn socket ->
  if socket.assigns.conversation_id == conv_id do
    Lavash.Socket.put_state(socket, :draft, socket.assigns.draft <> token)
  else
    socket
  end
end
```

This is the right shape for raw LiveView, but it's an escape
hatch in lavash terms. The natural DSL surface would be:

```elixir
messages do
  message {:llm_chunk, conv_id, token}, [:conv_id, :token]
       when @conversation_id == conv_id do
    set :draft, rx(@draft <> @token)
  end
end
```

Two missing pieces:

  - **Guard clauses on message patterns.** Today `message` takes a
    pattern and a body; there's no `when` clause that can
    reference state. The guard `@conversation_id == conv_id` would
    pre-filter at dispatch time instead of inside a `run fn`.
  - **`set` referencing pattern-bound variables.** `@token` here
    would be the bound `token` from the pattern, not a `state`
    field. Lavash's transformer would need to recognize binds in
    `rx()` bodies and treat them as locals rather than state
    refs.

Without those, the `run fn` escape hatch carries the body, but
the body is still mostly declarative — it's just spelled
imperatively.

### 2. No first-class "task we own"

`Task.start/1` runs unsupervised; cancelling means "send a
poison pill or just wait for the task to send chunks we ignore."
The demo uses the "increment conversation_id, ignore stale
chunks" trick because there's no DSL way to hold a task pid.

What I wanted:

```elixir
async :llm_response do
  run fn assigns ->
    FakeLLM.stream(assigns.input, self(), assigns.conversation_id)
  end
end

actions do
  action :submit do
    set :messages, rx(...)
    fire :llm_response       # starts the task
  end

  action :cancel do
    cancel :llm_response    # stops the running task
  end
end
```

The existing `async :foo` declaration is one-shot — it expects a
return value, not a stream of `send/2` calls. A streaming
variant might be:

```elixir
async_stream :llm_response do
  emits {:llm_chunk, _, _} | {:llm_done, _}

  run fn assigns, emit ->
    response = call_llm(assigns.input)
    Enum.each(tokens(response), fn t ->
      emit.({:llm_chunk, assigns.conversation_id, t})
    end)
    emit.({:llm_done, assigns.conversation_id})
  end
end
```

`emit` is a closure the runtime provides that does
`send(self(), {:llm_chunk, ...})` AND tracks the task. `cancel`
becomes a real cancellation. The `emits` declaration tells
lavash what message shapes to dispatch (and could even auto-wire
the corresponding `message` clauses if you go further).

### 3. Streaming + `optimistic: true` is a compile warning, not an error

I set `state :draft, optimistic: true` because every other state
field on this LiveView is optimistic and removing it felt
inconsistent. But `draft` is *server-authoritative* — there's no
way the client can predict the next token, so the JS optimistic
machinery has nothing to do for this field.

Lavash doesn't catch this; the JS just generates a no-op
optimistic patch. The runtime cost is small, but the
**conceptual** cost is that the developer doesn't know whether
`optimistic: true` is doing anything for a given field.

What would help:

  - **Per-field origin annotation.** `state :draft, :string,
    from: :stream` (or `:server`) would tell lavash "this only
    changes via server messages, don't bother with optimistic
    machinery." The validator could then complain about
    `optimistic: true` on a `:server` field.

### 4. The `messages` clause runs the reactive recompute every chunk

Each `:llm_chunk` message triggers `Reactive.recompute()` because
that's how `messages` bodies work — they're regular state
mutations. For a 200-token response that's 200 recomputes.

For this demo it's fine; nothing depends on `@draft` except the
template (which has to re-render anyway). But for a more
complex LV where a calc reads from `@draft` (e.g. token count,
syntax-highlighted markdown), each chunk triggers the full
dep graph. There's no batch mode.

What would help:

  - **Batch / coalesce mode on `messages`.** `message {:llm_chunk,
    ...}, batch: true do ... end` — coalesce multiple incoming
    chunks within a render frame, recompute once at flush.
  - **Marking calcs as "stream-friendly."** `calculate
    :token_count, rx(...), incremental: true` would let lavash
    compute the delta rather than redoing the whole calc.

Both are real LiveView performance problems — they're not
lavash-specific — but lavash's reactive graph makes the cost
more visible.

### 5. No DSL surface for "append to a typed collection"

`set :messages, rx(@messages ++ [new])` works but is awkward.
The shape is so common in chat UIs (and notification streams,
log tails, etc.) that a dedicated op would clean it up:

```elixir
action :submit do
  push :messages, rx(%{role: "user", content: String.trim(@input)})
  ...
end
```

`push :field, value` would be sugar for `set :field, rx(@field
++ [value])` with two bonuses:

  - The optimistic JS transpiler could emit a more efficient
    diff (the merge walker already handles append-only arrays;
    the JS would just push to the local array rather than
    reassigning).
  - The validator could check that `:messages` is `{:array, _}`
    typed and that the value matches the inner type.

Same for `pop`, `shift`, `unshift`, `update_at`. These exist in
JS arrays and Elixir's `List`/`Enum` but as ad-hoc patterns;
making them first-class ops would map straight to the optimistic
side.

### 6. Phoenix.LiveView.Streams aren't reachable from lavash

The big LV primitive specifically designed for this case is
`stream/3` — append-only collections that don't re-send the
whole list on every update. Lavash doesn't expose `stream`. For
this demo I sidestepped it (the message history is small enough
that resending the whole array is fine), but a real chat app
with hundreds of turns would want stream semantics.

What would help:

  - **`stream :name, {:array, :map}` as a state-field flavor.**
    Same shape as `state` but emits via LV streams rather than
    full diffs. The lavash reactive layer would need to know
    that `@messages` is stream-typed and that `rx(@messages ++
    [...])` should desugar to `stream_insert(socket, :messages,
    new_msg, at: -1)` rather than a full reassign.

This would also resolve #5 (append op) since streams *are*
append-friendly by design.

---

## Three primitives that would make streaming feel natural

If I had to pick the three that would have the most impact:

### 1. `async_stream :name do emits ... ; run fn assigns, emit -> ... end end`

Replaces the `Task.start + send(self(), ...)` pattern. The
runtime owns the task pid, so `cancel :name` is real
cancellation, not "ignore future messages." The `emits`
declaration types the message shapes the task will send;
companion `message` clauses can be generated or strongly
validated against that type.

### 2. Guard clauses on `message` patterns

```elixir
message {:llm_chunk, conv_id, token}, [:conv_id, :token]
     when @conversation_id == conv_id do
  set :draft, rx(@draft <> @token)
end
```

The runtime drops messages that don't match the guard before
invoking the body — cleaner than the `if ... do socket end`
boilerplate every chunk handler has today. Combined with #1
this means the conversation_id correlation pattern becomes one
declarative line.

### 3. `stream :name` as a first-class state flavor

```elixir
stream :messages, :map, default: []

actions do
  action :submit do
    push :messages, rx(%{role: "user", content: @input})
    fire :llm_response
  end
end
```

Map onto Phoenix's `stream/3` underneath, so the wire diff
ships only the new turn instead of the whole array. `@messages`
in the template renders via `Phoenix.LiveView.stream_for/2`
loops without the user having to know. Solves the perf cliff at
scale.

---

## What I'd build next

The fastest test of these ideas would be a small layer on top
of the existing async machinery:

1. **Build `cancel :name`** in `Lavash.Lifecycle.AsyncRuntime` —
   track the task pid in socket private state, `cancel` does
   `Process.exit(pid, :kill)`. Doesn't need any new DSL, just an
   addition to the existing `async :foo` declaration.

2. **Add `when` clause to `message`** — small change to
   `Lavash.Lifecycle.MessagesMacro` to capture the guard, runtime
   dispatcher checks it before invoking the body. The guard sees
   `socket.assigns` and pattern binds.

3. **Then** revisit whether `async_stream` and `stream :name`
   want their own DSL or whether they fold into the
   existing surface.

The chat demo is the regression test for all three: a working
implementation of streaming chat at every step of this
evolution, so we can see the DSL get *cleaner* as we add primitives
rather than just adding new surface.

---

## TL;DR

Streaming chat *works* in lavash today, but the implementation
leans on `run fn socket -> Lavash.Socket.put_state(...) end`
escape hatches for chunk handling, a manual
`conversation_id` counter to fake cancellation, and
`Task.start/1` for the unsupervised task itself.

Three small additions —
**`async_stream` with cancellation**, **guard clauses on
`message`**, **`stream :name` field flavor** — would let the
same demo be written entirely in declarative DSL with no escape
hatches.
