export default {
  doubled(state) {
    return (state.count * state.multiplier);
  }
,
__derives__: ["doubled"],
__fields__: [],
__graph__: {"doubled":{"deps":["multiplier","count"]}},
__animated__: []
};
