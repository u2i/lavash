export default {
  toggle_roast(state, value) {
    const list = state.roast || [];
    const idx = list.indexOf(value);
    if (idx >= 0) {
      return { roast: list.filter(v => v !== value) };
    } else {
      return { roast: [...list, value] };
    }
  }
,
  roast_chips(state) {
    const ACTIVE = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-primary text-primary-content border-primary";
    const INACTIVE = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50";
    const values = ["light","medium","medium_dark","dark"];
    const selected = state.roast || [];
    const result = {};
    for (const v of values) {
      result[v] = selected.includes(v) ? ACTIVE : INACTIVE;
    }
    return result;
  }
,
  toggle_in_stock(state) {
    return { in_stock: !state.in_stock };
  }
,
  in_stock_chip(state) {
    const ACTIVE = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-primary text-primary-content border-primary";
    const INACTIVE = "px-3 py-1.5 text-sm rounded-full border transition-colors cursor-pointer bg-base-100 text-base-content/70 border-base-300 hover:border-primary/50";
    return state.in_stock ? ACTIVE : INACTIVE;
  }
,
__derives__: ["roast_chips","in_stock_chip"],
__fields__: [],
__graph__: {"in_stock_chip":{"deps":["in_stock"]},"roast_chips":{"deps":["roast"]}},
__animated__: []
};
