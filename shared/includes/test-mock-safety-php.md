# Mock Safety Rules — PHP

> Stack-specific mock rules for PHPUnit, Codeception, Yii2, Laravel.
> Universal rules are in `test-mock-safety-core.md`.

1. **`onlyMethods()` vs `addMethods()` in PHPUnit** — `onlyMethods()` is for methods that EXIST on the class (including inherited/trait methods). `addMethods()` is for methods that DON'T exist and are dispatched via `__call()`. Using the wrong one: `onlyMethods(['magicMethod'])` → error. `addMethods(['realMethod'])` → silently creates a SECOND method that shadows the real one, causing false passes.
2. **`createMock()` vs `getMockBuilder()`** — `createMock()` auto-stubs ALL methods (returns null/default). Quick for simple cases. `getMockBuilder()` gives control: `disableOriginalConstructor()`, `onlyMethods()`, `addMethods()`. Use `getMockBuilder()` when: constructor has side effects, you need to mix real + magic methods, or you need partial mocking.
3. **Codeception `_before()` / `_after()` not `setUp()` / `tearDown()`** — Codeception Unit tests use `_before()` and `_after()` lifecycle hooks, not PHPUnit's `setUp()`/`tearDown()`. Using the wrong one: hooks may not fire, mocks not reset, state leaks between tests.
4. **Yii2/Laravel static singletons** — never mock `Yii::$app` or `App::make()` globally. Inject the mock via constructor or public property. If the service reads `Yii::$app->component` internally, either: (a) refactor to accept the dep in constructor, or (b) use a test application config that replaces the component. Global mock → leaks across tests.
5. **PHPUnit mock reset** — PHPUnit creates fresh mocks per test method by default (each test method gets a new test case instance). But if you store mocks in class properties via `_before()`, they persist. Always create mocks in `_before()`, never in the constructor or class property initializer.
