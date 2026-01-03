export default {
  has_filters(state) {
    return ((((((state.search !== "") || (state.category_id !== null)) || (state.in_stock !== null)) || (state.min_price !== null)) || (state.max_price !== null)) || (state.min_rating !== null));
  }
,
__derives__: ["has_filters"],
__fields__: [],
__graph__: {"has_filters":{"deps":["min_rating","max_price","min_price","in_stock","category_id","search"]}}
};
