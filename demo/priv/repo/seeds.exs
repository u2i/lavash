alias Demo.Catalog
alias Demo.Catalog.Category

# Create coffee categories
categories =
  [
    {"Single Origin", "single-origin"},
    {"Blends", "blends"},
    {"Espresso", "espresso"},
    {"Decaf", "decaf"},
    {"Limited Edition", "limited-edition"}
  ]
  |> Enum.map(fn {name, slug} ->
    {:ok, cat} = Catalog.create_category(%{name: name, slug: slug})
    {name, cat}
  end)
  |> Map.new()

coffees = [
  # Single Origin
  %{
    name: "Ethiopian Yirgacheffe",
    description: "Bright and complex with a wine-like quality",
    category: "Single Origin",
    origin: "Ethiopia",
    roast_level: :light,
    tasting_notes: "Blueberry, jasmine, lemon zest, honey",
    price: 18.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.9
  },
  %{
    name: "Colombian Supremo",
    description: "Well-balanced with a rich, full body",
    category: "Single Origin",
    origin: "Colombia",
    roast_level: :medium,
    tasting_notes: "Caramel, red apple, milk chocolate, nutty",
    price: 16.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.7
  },
  %{
    name: "Sumatra Mandheling",
    description: "Earthy and bold with low acidity",
    category: "Single Origin",
    origin: "Indonesia",
    roast_level: :dark,
    tasting_notes: "Cedar, dark chocolate, tobacco, earthy",
    price: 17.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.6
  },
  %{
    name: "Kenya AA",
    description: "Vibrant and juicy with bright acidity",
    category: "Single Origin",
    origin: "Kenya",
    roast_level: :medium,
    tasting_notes: "Blackcurrant, grapefruit, brown sugar, wine",
    price: 19.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.8
  },
  %{
    name: "Guatemala Antigua",
    description: "Smooth and spicy with chocolate undertones",
    category: "Single Origin",
    origin: "Guatemala",
    roast_level: :medium,
    tasting_notes: "Dark chocolate, spice, smoke, caramel",
    price: 17.49,
    weight_oz: 12,
    in_stock: false,
    rating: 4.5
  },
  %{
    name: "Costa Rica Tarrazú",
    description: "Clean and bright with excellent balance",
    category: "Single Origin",
    origin: "Costa Rica",
    roast_level: :light,
    tasting_notes: "Honey, citrus, vanilla, almond",
    price: 18.49,
    weight_oz: 12,
    in_stock: true,
    rating: 4.7
  },

  # Blends
  %{
    name: "House Blend",
    description: "Our signature everyday coffee, smooth and approachable",
    category: "Blends",
    origin: "Central & South America",
    roast_level: :medium,
    tasting_notes: "Chocolate, caramel, toasted nuts, balanced",
    price: 14.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.5
  },
  %{
    name: "Breakfast Blend",
    description: "Bright and lively, perfect for mornings",
    category: "Blends",
    origin: "Africa & Latin America",
    roast_level: :light,
    tasting_notes: "Citrus, honey, tea-like, floral",
    price: 15.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.4
  },
  %{
    name: "Dark Roast Blend",
    description: "Bold and smoky for those who like it strong",
    category: "Blends",
    origin: "Indonesia & Latin America",
    roast_level: :dark,
    tasting_notes: "Smoky, bittersweet chocolate, molasses",
    price: 15.49,
    weight_oz: 12,
    in_stock: true,
    rating: 4.3
  },

  # Espresso
  %{
    name: "Classic Espresso",
    description: "Rich crema and balanced extraction",
    category: "Espresso",
    origin: "Brazil & Colombia",
    roast_level: :medium_dark,
    tasting_notes: "Hazelnut, dark chocolate, brown sugar, syrupy",
    price: 17.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.8
  },
  %{
    name: "Italian Roast Espresso",
    description: "Traditional dark roast for authentic espresso",
    category: "Espresso",
    origin: "Brazil & Indonesia",
    roast_level: :dark,
    tasting_notes: "Bittersweet, smoky, leather, intense",
    price: 16.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.6
  },
  %{
    name: "Single Origin Espresso",
    description: "Bright and fruity for espresso purists",
    category: "Espresso",
    origin: "Ethiopia",
    roast_level: :medium,
    tasting_notes: "Berry, citrus, floral, complex",
    price: 19.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.7
  },

  # Decaf
  %{
    name: "Decaf Swiss Water",
    description: "Chemical-free decaf that tastes like real coffee",
    category: "Decaf",
    origin: "Colombia",
    roast_level: :medium,
    tasting_notes: "Chocolate, caramel, smooth, clean",
    price: 17.99,
    weight_oz: 12,
    in_stock: true,
    rating: 4.4
  },
  %{
    name: "Decaf Espresso",
    description: "Full-flavored decaf for evening espresso",
    category: "Decaf",
    origin: "Brazil & Colombia",
    roast_level: :medium_dark,
    tasting_notes: "Nutty, chocolate, mild, balanced",
    price: 18.49,
    weight_oz: 12,
    in_stock: false,
    rating: 4.3
  },

  # Limited Edition
  %{
    name: "Panama Geisha",
    description: "Rare and exceptional, a true coffee experience",
    category: "Limited Edition",
    origin: "Panama",
    roast_level: :light,
    tasting_notes: "Jasmine, bergamot, peach, tropical fruit",
    price: 49.99,
    weight_oz: 8,
    in_stock: true,
    rating: 5.0
  },
  %{
    name: "Jamaica Blue Mountain",
    description: "Legendary smoothness from the Blue Mountains",
    category: "Limited Edition",
    origin: "Jamaica",
    roast_level: :medium,
    tasting_notes: "Sweet herbs, nuts, no bitterness, creamy",
    price: 54.99,
    weight_oz: 8,
    in_stock: true,
    rating: 4.9
  }
]

for coffee_attrs <- coffees do
  category = Map.fetch!(categories, coffee_attrs.category)

  attrs =
    coffee_attrs
    |> Map.delete(:category)
    |> Map.put(:category_id, category.id)

  {:ok, _product} = Catalog.create_product(attrs)
end

IO.puts("Seeded #{map_size(categories)} categories and #{length(coffees)} coffees")
