// CLEAN: introspection off in prod + depthLimit validation rule.
const { ApolloServer } = require('apollo-server');
const depthLimit = require('graphql-depth-limit');
module.exports = new ApolloServer({
  typeDefs, resolvers,
  introspection: process.env.NODE_ENV !== 'production' ? true : false,
  validationRules: [depthLimit(7)],
});
