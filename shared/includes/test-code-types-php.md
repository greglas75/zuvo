# Test Code-Type Templates — PHP

> Stack-specific mock templates and patterns for PHPUnit, Codeception, Yii2, Laravel.
> Core classification rules are in `test-code-types-core.md`.

## PHPUnit Mock Fundamentals

### `getMockBuilder` — real methods vs magic methods

> **`addMethods()` IS GONE.** Deprecated in PHPUnit 10.1, warning in 11, **removed without
> replacement in PHPUnit 12** (Feb 2025; PHPUnit 11 went EOL Feb 2026). Any example calling it
> fatals on every currently-supported PHPUnit. Detect the project's major
> (`composer show phpunit/phpunit`) before choosing a pattern below.

```php
// REAL methods (declared in the class or a trait): onlyMethods() — unchanged in every major
$mock = $this->getMockBuilder(S3Client::class)
    ->disableOriginalConstructor()
    ->onlyMethods(['upload'])  // upload() is declared in S3ClientTrait
    ->getMock();

// MAGIC methods (__call-dispatched) on PHPUnit 12+: there is no builder API for undeclared
// methods any more. CAUTION: mocking the SDK INTERFACE usually does NOT help — AWS declares
// these via `@method` docblocks on the interface too, so PHPUnit still sees no real method.
// Verify first: does the interface DECLARE the method in code (not a docblock)?
//   php -r 'var_dump(method_exists(\Aws\S3\S3ClientInterface::class, "getObject"));'
// true  -> $this->createMock(S3ClientInterface::class) works
// false -> use the SDK's own test double (preferred for AWS): MockHandler
use Aws\MockHandler; use Aws\Result;
$handler = new MockHandler([new Result(['Body' => 'x'])]);   // queue one Result per call
$s3 = new S3Client(['region' => 'us-east-1', 'version' => 'latest', 'handler' => $handler]);

// Any SDK without a test double? Hand-rolled stub (explicit, version-proof):
$mock = new class extends S3Client {
    public function __construct() {}                    // skip the SDK constructor
    public function getObject(array $args = []): \Aws\Result { return new \Aws\Result([]); }
};

// PHPUnit <= 11 ONLY (legacy repos): addMethods() still exists but warns.
// $mock = $this->getMockBuilder(S3Client::class)->addMethods(['getObject'])->getMock();
```

**Key rule:** `onlyMethods()` auto-stubs ALL other real methods (they return null/default) and REJECTS a method the class does not declare — that rejection is the whole point, and on PHPUnit 12 there is no `addMethods()` escape hatch. For `__call()`-dispatched SDK methods, mock the interface or hand-roll a stub.

**When unsure if a method is real or magic:** check whether it is declared in the class or its traits. Not found → `__call()` → interface/stub route above (never `onlyMethods()`, which will throw).

### `createMock()` vs `getMockBuilder()`

- `createMock(Foo::class)` — auto-stubs ALL methods (returns null/default). Quick for simple cases.
- `getMockBuilder(Foo::class)` — gives control: `disableOriginalConstructor()`, `onlyMethods()` (and, on PHPUnit <= 11 only, the removed `addMethods()`).

Use `getMockBuilder()` when:
- Constructor has side effects (SDK clients, DB connections)
- You need partial control over which real methods stay real
- You need partial mocking (`onlyMethods` leaves others real)

## AWS SDK Mock Patterns

AWS SDK services use traits for some methods and `__call()` for others:

| Method | Type | Mock with (PHPUnit 12+) |
|--------|------|--------------------------|
| `upload()` | **real** (declared in `S3ClientTrait`) | `onlyMethods(['upload'])` |
| `putObject()`, `getObject()`, `deleteObject()` | **magic** (`__call`) | `Aws\MockHandler` (preferred) or hand-rolled stub — interface mocking only if `method_exists` is true |
| `doesObjectExist()` | **magic** | `MockHandler` / stub |
| `getObjectUrl()` | **magic** | `MockHandler` / stub |

Verify per SDK version rather than trusting this table: a method that is magic today can become
declared in a later release, and `onlyMethods()` throws on the mismatch either way.

**S3Exception requires CommandInterface:**
```php
use Aws\CommandInterface;
use Aws\S3\Exception\S3Exception;

$command = $this->createMock(CommandInterface::class);
$mock->method('deleteObject')
    ->willThrowException(new S3Exception('Error message', $command));
```

## Codeception Unit Test Lifecycle

```php
class MyServiceTest extends \Codeception\Test\Unit
{
    protected UnitTester $tester;
    private MyService $service;
    private MockObject $mockDep;

    protected function _before(): void  // NOT setUp()
    {
        $this->mockDep = $this->createMock(Dependency::class);
        $this->service = new MyService($this->mockDep);
    }

    protected function _after(): void   // NOT tearDown()
    {
        // cleanup temp files, restore state
    }
}
```

**Critical:** Codeception uses `_before()` / `_after()`, NOT PHPUnit's `setUp()` / `tearDown()`. Using the wrong hooks: mocks may not fire, state leaks between tests.

## Yii2 Static Singletons

```php
// PREFERRED: If the service accepts the dep in constructor or has public property:
$this->service->client = $this->mockClient;

// ALTERNATIVE: If the service uses Yii::$app->component internally:
// Mock at the boundary — create a test application config that injects the mock.
// Do NOT mock Yii::$app globally — it leaks across tests.
```

**Yii::getAlias():** If production code uses `Yii::getAlias('@runtime')` for file paths, set the alias in `_before()`:
```php
Yii::setAlias('@runtime', sys_get_temp_dir() . '/test-runtime');
```

## Laravel Mock Patterns

```php
// Service binding in test:
$this->app->bind(PaymentGateway::class, function () {
    return $this->createMock(PaymentGateway::class);
});

// Facade mock:
Queue::fake();
Queue::assertPushed(ProcessOrder::class);

// Event mock:
Event::fake([OrderCreated::class]);
Event::assertDispatched(OrderCreated::class);
```

## Repetitive SERVICE Pattern (null-guard + try/catch)

When a PHP service has N methods with the same pattern:
```php
public function methodName($dto): bool|null|Result {
    if ($this->client === null) return false;  // null guard
    try {
        $result = $this->client->apiCall(...);  // delegate
        return $result;
    } catch (SomeException $e) {
        $this->log($e->getMessage());  // log
        return false;  // fallback
    }
}
```

Test each method with exactly 3 tests:
1. **Success:** mock delegate → returns expected → assert true/result
2. **Null-client:** set dep to null → assert false/null (no delegate called)
3. **Exception:** mock delegate → throws → assert false/null

For a service with 7 identical-pattern methods = 21 tests minimum. Use **per-pattern contract mode** (see test-contract.md).

**Watch for inconsistencies between methods** — e.g., one catches `Throwable` while others catch `S3Exception`. These are bugs, not style choices. Flag them in bug scan.
