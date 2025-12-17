alias Demo.Catalog
alias Demo.Catalog.Category

# Create categories first
categories =
  ["Electronics", "Books", "Clothing", "Home & Garden", "Sports"]
  |> Enum.map(fn name ->
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
    {:ok, cat} = Catalog.create_category(%{name: name, slug: slug})
    {name, cat}
  end)
  |> Map.new()

products = [
  # Electronics
  %{name: "Wireless Headphones", category: "Electronics", price: 79.99, in_stock: true, rating: 4.5},
  %{name: "Bluetooth Speaker", category: "Electronics", price: 49.99, in_stock: true, rating: 4.2},
  %{name: "USB-C Hub", category: "Electronics", price: 34.99, in_stock: true, rating: 4.7},
  %{name: "Mechanical Keyboard", category: "Electronics", price: 129.99, in_stock: false, rating: 4.8},
  %{name: "Wireless Mouse", category: "Electronics", price: 29.99, in_stock: true, rating: 4.1},
  %{name: "4K Monitor", category: "Electronics", price: 349.99, in_stock: true, rating: 4.6},
  %{name: "Webcam HD", category: "Electronics", price: 69.99, in_stock: false, rating: 4.0},
  %{name: "Power Bank", category: "Electronics", price: 39.99, in_stock: true, rating: 4.3},

  # Books
  %{name: "Elixir in Action", category: "Books", price: 44.99, in_stock: true, rating: 4.9},
  %{name: "Programming Phoenix", category: "Books", price: 39.99, in_stock: true, rating: 4.8},
  %{name: "Designing Data Applications", category: "Books", price: 49.99, in_stock: true, rating: 4.7},
  %{name: "The Pragmatic Programmer", category: "Books", price: 42.99, in_stock: false, rating: 4.9},
  %{name: "Clean Code", category: "Books", price: 37.99, in_stock: true, rating: 4.5},
  %{name: "Domain Driven Design", category: "Books", price: 54.99, in_stock: true, rating: 4.4},

  # Clothing
  %{name: "Cotton T-Shirt", category: "Clothing", price: 19.99, in_stock: true, rating: 4.2},
  %{name: "Denim Jeans", category: "Clothing", price: 59.99, in_stock: true, rating: 4.4},
  %{name: "Wool Sweater", category: "Clothing", price: 79.99, in_stock: false, rating: 4.6},
  %{name: "Running Shoes", category: "Clothing", price: 89.99, in_stock: true, rating: 4.5},
  %{name: "Winter Jacket", category: "Clothing", price: 149.99, in_stock: true, rating: 4.7},
  %{name: "Baseball Cap", category: "Clothing", price: 24.99, in_stock: true, rating: 4.0},

  # Home & Garden
  %{name: "Coffee Maker", category: "Home & Garden", price: 89.99, in_stock: true, rating: 4.3},
  %{name: "Air Purifier", category: "Home & Garden", price: 129.99, in_stock: true, rating: 4.5},
  %{name: "LED Desk Lamp", category: "Home & Garden", price: 34.99, in_stock: true, rating: 4.4},
  %{name: "Plant Pot Set", category: "Home & Garden", price: 29.99, in_stock: false, rating: 4.1},
  %{name: "Throw Blanket", category: "Home & Garden", price: 39.99, in_stock: true, rating: 4.6},
  %{name: "Kitchen Scale", category: "Home & Garden", price: 24.99, in_stock: true, rating: 4.2},

  # Sports
  %{name: "Yoga Mat", category: "Sports", price: 29.99, in_stock: true, rating: 4.5},
  %{name: "Dumbbell Set", category: "Sports", price: 79.99, in_stock: true, rating: 4.7},
  %{name: "Resistance Bands", category: "Sports", price: 19.99, in_stock: true, rating: 4.3},
  %{name: "Jump Rope", category: "Sports", price: 14.99, in_stock: true, rating: 4.1},
  %{name: "Water Bottle", category: "Sports", price: 24.99, in_stock: false, rating: 4.4},
  %{name: "Fitness Tracker", category: "Sports", price: 99.99, in_stock: true, rating: 4.2},
]

for product_attrs <- products do
  category = Map.fetch!(categories, product_attrs.category)

  attrs =
    product_attrs
    |> Map.delete(:category)
    |> Map.put(:category_id, category.id)

  {:ok, _product} = Catalog.create_product(attrs)
end

IO.puts("Seeded #{map_size(categories)} categories and #{length(products)} products")
