export default {
  is_open(state) {
    return (state.product_id !== null);
  }
,
__derives__: ["is_open"],
__fields__: [],
__graph__: {"is_open":{"deps":["product_id"]}}
};
