// VULNERABLE: introspection enabled in prod + no depth/complexity limit.
const { ApolloServer } = require('apollo-server');
module.exports = new ApolloServer({
  typeDefs, resolvers,
  introspection: true,            // graphql_introspection
  validationRules: [],            // graphql_depth_unbounded — no depthLimit
});
