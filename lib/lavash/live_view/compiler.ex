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
      def __lavash__(:inputs) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:inputs])
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
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
      end

      # Convenience accessors by storage type
      def __lavash__(:url_fields) do
        __lavash__(:inputs) |> Enum.filter(&(&1.from == :url))
      end

      def __lavash__(:socket_fields) do
        __lavash__(:inputs) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:inputs) |> Enum.filter(&(is_nil(&1.from) || &1.from == :ephemeral))
      end
    end
  end

  @doc """
  Normalize a derived field - extract depends_on from arguments and wrap run into compute.
  """
  def normalize_derived(%Lavash.Derived.Field{} = field) do
    # Extract depends_on from arguments
    depends_on =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        case arg.source do
          {:input, name} -> name
          {:result, name} -> name
          {:prop, name} -> name
          name when is_atom(name) -> name
        end
      end)

    # Build arg name mapping for the compute wrapper
    arg_mapping =
      (field.arguments || [])
      |> Enum.map(fn arg ->
        source_field =
          case arg.source do
            {:input, name} -> name
            {:result, name} -> name
            {:prop, name} -> name
            name when is_atom(name) -> name
          end
        {arg.name, source_field}
      end)

    # Create compute wrapper that maps state to argument names
    compute =
      if field.run do
        fn deps ->
          # Map the deps to use argument names
          mapped_deps =
            Enum.reduce(arg_mapping, %{}, fn {arg_name, source_field}, acc ->
              Map.put(acc, arg_name, Map.get(deps, source_field))
            end)

          # Call run with mapped deps and empty context
          field.run.(mapped_deps, %{})
        end
      else
        field.compute
      end

    %{field | depends_on: depends_on, compute: compute}
  end
end
