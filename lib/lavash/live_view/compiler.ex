defmodule Lavash.LiveView.Compiler do
  @moduledoc """
  Compiles the Lavash DSL into LiveView callbacks.
  """

  defmacro __before_compile__(env) do
    has_on_mount = Module.defines?(env.module, {:on_mount, 1})

    mount_callback =
      if has_on_mount do
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
            on_mount(socket)
          end
        end
      else
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
          end
        end
      end

    quote do
      unquote(mount_callback)

      @impl Phoenix.LiveView
      def handle_params(params, uri, socket) do
        Lavash.LiveView.Runtime.handle_params(__MODULE__, params, uri, socket)
      end

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) do
        Lavash.LiveView.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      @impl Phoenix.LiveView
      def handle_info(msg, socket) do
        Lavash.LiveView.Runtime.handle_info(__MODULE__, msg, socket)
      end

      # Introspection functions - entities from top_level? sections
      def __lavash__(:states) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
      end

      def __lavash__(:reads) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:reads])
      end

      def __lavash__(:forms) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:forms])
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
        |> Enum.map(&Lavash.LiveView.Compiler.normalize_derived/1)
      end

      def __lavash__(:actions) do
        declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        declared_actions ++ setter_actions
      end

      # Convenience accessors by storage type
      def __lavash__(:url_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :url))
      end

      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(is_nil(&1.from) || &1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.optimistic == true))
      end
    end
  end

  @doc """
  Generate synthetic setter actions for state fields with setter: true or optimistic: true.
  Optimistic fields automatically get setters to enable client-side optimistic updates.
  """
  def generate_setter_actions(module) do
    module.__lavash__(:states)
    |> Enum.filter(&(&1.setter || &1.optimistic))
    |> Enum.map(fn state ->
      %Lavash.Actions.Action{
        name: :"set_#{state.name}",
        params: [:value],
        when: [],
        sets: [
          %Lavash.Actions.Set{
            field: state.name,
            value: & &1.params.value
          }
        ],
        updates: [],
        effects: [],
        submits: [],
        navigates: [],
        flashes: [],
        invokes: []
      }
    end)
  end

  @doc """
  Normalize a derived field - extract depends_on from arguments and wrap run into compute.
  """
  def normalize_derived(%Lavash.Derived.Field{} = field) do
    # Extract depends_on from arguments
    # If source is nil, default to state(arg_name)
    depends_on =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        extract_source_field(arg.source, arg.name)
      end)

    # Build arg name mapping for the compute wrapper
    # Each entry is {arg_name, source_field, transform}
    arg_mapping =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        source_field = extract_source_field(arg.source, arg.name)
        {arg.name, source_field, arg.transform}
      end)

    # Create compute wrapper that maps state to argument names
    compute =
      if field.run do
        fn deps ->
          # Map the deps to use argument names, applying transforms
          mapped_deps =
            Enum.reduce(arg_mapping, %{}, fn {arg_name, source_field, transform}, acc ->
              value = Map.get(deps, source_field)
              value = if transform, do: transform.(value), else: value
              Map.put(acc, arg_name, value)
            end)

          # Call run with mapped deps and empty context
          field.run.(mapped_deps, %{})
        end
      else
        field.compute
      end

    %{field | depends_on: depends_on, compute: compute}
  end

  # Extract the source field name from source tuple, defaulting to state(arg_name) if nil
  defp extract_source_field(source, arg_name) do
    case source do
      {:state, name} -> name
      {:result, name} -> name
      {:prop, name} -> name
      name when is_atom(name) and not is_nil(name) -> name
      # Default to same-named state field
      nil -> arg_name
    end
  end
end
