## verify-tests: PHP projects on Codeception + Infection

- A PHP repo with `codeception.yml` now runs through `codecept run <suite> <spec>` instead of bare
  `phpunit`. Codeception test classes error out under phpunit ("Service di is not defined"), so
  every such pass read as a red suite and no verification receipt could ever be written.
- Coverage comes from Codeception's text report scoped to the production file (lines, methods;
  branches reported as not measured rather than 0%). Mutation runs Infection with its Codeception
  adapter (`--filter=<file> --only-covering-test-cases`); survivors land in the same
  `.survivors.json` report as Stryker's, via a shared `record_survivors()`.
- `ZUVO_VERIFY_EXEC` prefixes those commands for toolchains that are not in the shell — a dev
  container (`docker exec -w /var/www/html app-php`) or the test farm (`rt --full --light` — `--full`
  keeps the coverage report, which rt would otherwise condense away with the rest of a long job).
