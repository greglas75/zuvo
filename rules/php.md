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

---

## Semgrep-Derived Patterns

### unserialize -- use json_decode instead
```php
// NEVER -- unserialize with user input (RCE risk)
$data = unserialize($_POST['data']);
// ALWAYS -- JSON or allowed_classes restriction
$data = json_decode($_POST['data'], true);
// If unserialize needed: unserialize($data, ['allowed_classes' => false]);
```

### exec/shell_exec -- avoid or escapeshellarg
```php
// NEVER -- user input in exec without escaping
exec("convert " . $filename . " output.png");
// ALWAYS -- escapeshellarg per argument
exec("convert " . escapeshellarg($filename) . " output.png");
```

### eval -- never use
```php
// NEVER
eval($userCode);
$result = eval('return ' . $expression . ';');
// ALWAYS -- use structured alternatives (match/switch, Symfony ExpressionLanguage)
```

### md5 loose equality -- use strict comparison
```php
// NEVER -- loose comparison enables type juggling bypass
if (md5($input) == $storedHash) { /* auth */ }
// ALWAYS -- strict comparison + timing-safe
if (hash_equals($storedHash, md5($input))) { /* auth */ }
// Better: use password_hash/password_verify instead of md5
```

### mcrypt -- use openssl or sodium
```php
// NEVER -- mcrypt is removed since PHP 7.2
mcrypt_encrypt(MCRYPT_RIJNDAEL_128, $key, $data, MCRYPT_MODE_CBC, $iv);
// ALWAYS -- openssl or sodium
openssl_encrypt($data, 'aes-256-cbc', $key, 0, $iv);
```

### unlink -- validate path before delete
```php
// NEVER -- user-controlled path in unlink
unlink($uploadDir . '/' . $_GET['file']);
// ALWAYS -- basename + realpath guard
$safePath = realpath($uploadDir . '/' . basename($_GET['file']));
if ($safePath && str_starts_with($safePath, $uploadDir)) {
    unlink($safePath);
}
```

### FTP -- use SFTP/SCP
```php
// NEVER -- plaintext FTP
ftp_connect($host);
// ALWAYS -- SFTP via ssh2 or phpseclib
$sftp = new \phpseclib3\Net\SFTP($host);
```

### Open redirect -- validate redirect URL
```php
// NEVER -- redirect to user-supplied URL
return $this->redirect($request->get('returnUrl'));
// ALWAYS -- allowlist or relative-only
$url = $request->get('returnUrl', '/');
if (!str_starts_with($url, '/') || str_starts_with($url, '//')) {
    $url = '/';
}
return $this->redirect($url);
```

---

## SSRF Prevention (curl / Guzzle / file_get_contents)

Any code making HTTP requests to user-supplied URLs must apply all three layers:

**Layer 1: Protocol allowlist**
```php
$scheme = strtolower(parse_url($userInput, PHP_URL_SCHEME));
if (!in_array($scheme, ['https', 'http'], true)) {
    throw new \InvalidArgumentException("Protocol not allowed: $scheme");
}
```

**Layer 2: Private IP range block (after DNS resolution)**
```php
$host = gethostbyname(parse_url($userInput, PHP_URL_HOST));
$blocked = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16'];
// Block loopback, private, and link-local (metadata services)
```

**Layer 3: Timeout on all outbound requests**
```php
$client = new \GuzzleHttp\Client([
    'timeout' => 5, 'connect_timeout' => 2,
    'allow_redirects' => ['max' => 3, 'strict' => true],
]);
```

---

## File Upload Security

```php
// Size limit in server code, not just nginx
['file', 'file', 'maxSize' => 10 * 1024 * 1024, 'extensions' => ['jpg', 'png', 'pdf'],
    'checkExtensionByMimeType' => true];

// MIME sniffing -- read magic bytes, don't trust Content-Type
$finfo = new \finfo(FILEINFO_MIME_TYPE);
$mime = $finfo->file($file->tempName);

// Storage outside webroot, random filename
$safeName = bin2hex(random_bytes(16)) . '.' . $file->extension;
$file->saveAs($storagePath . $safeName);  // NOT @webroot

// Block executable extensions even if MIME looks OK
$blocked = ['php', 'php3', 'phtml', 'phar', 'asp', 'sh', 'exe', 'bat'];
```

---

## Multi-Tenant Isolation

Every query on tenant-scoped resources must include a tenant/owner filter at the query level. Access control alone is NOT sufficient.

```php
// NEVER -- guard only, no query filter
$this->checkPermission('view-order');
return Order::findOne($id);  // returns ANY order

// ALWAYS -- guard + query filter
return Order::find()
    ->where(['id' => $id])
    ->andWhere(['userId' => $currentUserId])
    ->one() ?? throw new ForbiddenHttpException();
```

---

## Bounded Queries

```php
// NEVER -- unbounded ->all() on list endpoints
$orders = Order::find()->where(['status' => 'active'])->all();

// ALWAYS -- paginate
$query = Order::find()->where(['status' => 'active']);
$pages = new Pagination(['totalCount' => $query->count(), 'pageSize' => 50]);
$orders = $query->offset($pages->offset)->limit($pages->limit)->all();
```

---

## Transaction Rules

```php
// Side effects AFTER commit, never inside transaction
$transaction = Yii::$app->db->beginTransaction();
try {
    $order->save(false);
    $transaction->commit();
} catch (\Exception $e) {
    $transaction->rollBack();
    throw $e;
}
// Safe: only reached if commit succeeded
Yii::$app->queue->push(new SendConfirmationJob(['orderId' => $order->id]));
```

---

## Session / CSRF Security

```php
// Cookie settings
'session' => [
    'cookieParams' => ['httponly' => true, 'secure' => YII_ENV_PROD, 'samesite' => 'Lax'],
],
'request' => [
    'enableCsrfValidation' => true,  // never disable globally
    'cookieValidationKey' => getenv('COOKIE_KEY'),  // never hardcode
],
```
