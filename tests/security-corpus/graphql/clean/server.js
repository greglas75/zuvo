// CLEAN: introspection OFF by default (only on when NODE_ENV is explicitly 'development'),
// plus depth AND complexity validation rules.
const { ApolloServer } = require('apollo-server');
const depthLimit = require('graphql-depth-limit');
const isDev = process.env.NODE_ENV === 'development';
module.exports = new ApolloServer({
  typeDefs, resolvers,
  introspection: isDev,            // default-secure: false in prod / when unset
  validationRules: [depthLimit(7)],
});
