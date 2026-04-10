# Test Code-Type Templates — PHP

> Stack-specific mock templates and patterns for PHPUnit, Codeception, Yii2, Laravel.
> Core classification rules are in `test-code-types-core.md`.

## PHPUnit Mock Fundamentals

### `getMockBuilder` — real methods vs magic methods

```php
// REAL methods (defined in class or trait): use onlyMethods()
$mock = $this->getMockBuilder(S3Client::class)
    ->disableOriginalConstructor()
    ->onlyMethods(['upload'])  // upload() exists in AwsClientTrait
    ->getMock();

// MAGIC methods (__call dispatched): use addMethods()
$mock = $this->getMockBuilder(S3Client::class)
    ->disableOriginalConstructor()
    ->addMethods(['getObject', 'deleteObject'])  // these go through __call()
    ->getMock();

// MIXED (real + magic): combine both
$mock = $this->getMockBuilder(S3Client::class)
    ->disableOriginalConstructor()
    ->onlyMethods(['upload'])         // real
    ->addMethods(['getObject'])       // magic
    ->getMock();
```

**Key rule:** `onlyMethods()` auto-stubs ALL other real methods (they return null/default). `addMethods()` declares methods that don't exist on the class — required for `__call()` magic.

**When unsure if a method is real or magic:** Check if the method exists in the class or its traits. If not found → it's dispatched via `__call()` → use `addMethods()`.

### `createMock()` vs `getMockBuilder()`

- `createMock(Foo::class)` — auto-stubs ALL methods (returns null/default). Quick for simple cases.
- `getMockBuilder(Foo::class)` — gives control: `disableOriginalConstructor()`, `onlyMethods()`, `addMethods()`.

Use `getMockBuilder()` when:
- Constructor has side effects (SDK clients, DB connections)
- You need to mix real + magic methods
- You need partial mocking (`onlyMethods` leaves others real)

## AWS SDK Mock Patterns

AWS SDK services use traits for some methods and `__call()` for others:

| Method | Type | Mock with |
|--------|------|-----------|
| `upload()`, `putObject()` | **real** (AwsClientTrait) | `onlyMethods()` |
| `getObject()`, `deleteObject()` | **magic** (`__call`) | `addMethods()` |
| `doesObjectExist()` | **magic** | `addMethods()` |
| `getObjectUrl()` | **magic** | `addMethods()` |

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
