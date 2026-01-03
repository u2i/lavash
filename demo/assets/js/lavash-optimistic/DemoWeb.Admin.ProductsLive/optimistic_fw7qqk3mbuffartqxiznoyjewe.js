export default {
  has_filters(state) {
    return (((state.search !== "") || (state.category_id !== null)) || (state.in_stock !== null));
  }
,
__derives__: ["has_filters"],
__fields__: [],
__graph__: {"has_filters":{"deps":["in_stock","category_id","search"]}}
};
