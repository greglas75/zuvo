# PHP Defensive Patterns

Active when PHP is detected in the project (composer.json, .php files). These patterns complement the framework-specific rules (Yii2, Laravel).

---

### Type juggling -- use strict comparison everywhere
```php
// NEVER -- loose comparison (type juggling exploits)
if ($status == 0) { ... }           // "abc" == 0 is TRUE in PHP!
if ($token == null) { ... }         // "" == null is TRUE
in_array($role, $allowed);          // loose by default

// ALWAYS -- strict
if ($status === 0) { ... }
if ($token === null) { ... }
in_array($role, $allowed, true);    // strict=true
```

### Dead code after return/throw/exit
```php
// NEVER -- unreachable code
function validate($data) {
    if (!$data) {
        throw new \InvalidArgumentException('No data');
    }
    return false;  // unreachable after throw
    $this->log('validation failed');  // dead code
}

// ALWAYS -- remove dead code or fix logic
function validate($data) {
    if (!$data) {
        throw new \InvalidArgumentException('No data');
    }
    return true;
}
```

### SQL string concatenation -- use prepared statements
```php
// NEVER -- variables concatenated into SQL
$query = "SELECT * FROM users WHERE email = '" . $email . "'";
$db->query("DELETE FROM sessions WHERE id = $id");

// ALWAYS -- prepared statements
$stmt = $pdo->prepare("SELECT * FROM users WHERE email = ?");
$stmt->execute([$email]);
```

### Empty function body -- add TODO or remove
```php
// NEVER -- empty method without explanation
public function onError($event) {}
protected function beforeSave() {}

// ALWAYS -- TODO comment or throw
protected function beforeSave() {
    // TODO: implement validation before save
    throw new \RuntimeException('Not implemented');
}
```

### Too many parameters -- max 4, use object/DTO
```php
// NEVER -- function with 6+ parameters
function createSurvey($title, $lang, $orgId, $type, $status, $quota, $loi) { }

// ALWAYS -- options object / DTO
function createSurvey(CreateSurveyDto $dto) { }
```

### Catch generic Exception -- catch specific
```php
// NEVER -- catch all exceptions (masks real errors)
try { $this->process($data); }
catch (\Exception $e) { return null; }

// ALWAYS -- catch specific, let unexpected bubble up
try { $this->process($data); }
catch (ValidationException $e) { return $this->validationError($e); }
catch (NotFoundException $e) { return null; }
// \RuntimeException, \LogicException -- let them crash
```

### Nested ternary -- unreadable, use if/match
```php
// NEVER -- nested ternary (PHP 8 deprecated this)
$label = $status === 'a' ? 'Active' : ($status === 'p' ? 'Pending' : 'Unknown');

// ALWAYS -- match expression (PHP 8+)
$label = match($status) {
    'a' => 'Active',
    'p' => 'Pending',
    default => 'Unknown',
};
```
