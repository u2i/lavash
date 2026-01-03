export default {
  has_filters(state) {
    return ((((((state.search !== "") || (state.category !== "")) || (state.in_stock !== "")) || (state.min_price !== null)) || (state.max_price !== null)) || (state.min_rating !== null));
  }
,
__derives__: ["has_filters"],
__fields__: [],
__graph__: {"has_filters":{"deps":["min_rating","max_price","min_price","in_stock","category","search"]}}
};
