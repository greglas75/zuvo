# Yii2 Performance Checklist

Active when Yii2 is detected (`composer.json` has `yiisoft/yii2`, or `Yii::$app` in source).
Complements `php.md` (general PHP patterns).

---

## Caching

### DbMessageSource caching enabled in production
```php
// config/main.php or web.php
'i18n' => [
    'translations' => [
        '*' => [
            'class' => 'yii\i18n\DbMessageSource',
            'enableCaching' => true,          // MUST be true in prod/console
            'cachingDuration' => 3600,
        ],
    ],
],
```
Check test/dev envs may disable it; prod + console MUST enable.

### Query / schema cache on the DB component
```php
// config/db.php
'db' => [
    'class' => 'yii\db\Connection',
    'enableQueryCache'    => true,
    'enableSchemaCache'   => true,
    'schemaCacheDuration' => 3600,
    'schemaCache'         => 'cache',
],
```

### The `cache` component is actually defined
If any component references `'cache'`, the component MUST exist in the same config tree
(web.php, console.php, or env-local). A dangling reference silently degrades every
`->cache()` call to a no-op.

### Hot read queries use `->cache()` + TagDependency
```php
// NEVER -- hot read without cache
$orgs = Organisation::find()->where(['status' => 'active'])->all();

// ALWAYS -- cached with tag invalidation on write
$orgs = Organisation::getDb()->cache(function () {
    return Organisation::find()->where(['status' => 'active'])->all();
}, 3600, new TagDependency(['tags' => ['organisations']]));

// On write:
TagDependency::invalidate(Yii::$app->cache, ['organisations']);
```

---

## Query Patterns

### `->all()` vs `->batch()` / `->each()` ratio
In `commands/`, console scripts, and migrations the ratio of `->all()` to
`->batch()`/`->each()` should stay below 10:1. Unbounded `->all()` on a table that
grows OOM-kills the worker eventually.

```php
// NEVER -- load all rows into memory
foreach (Order::find()->all() as $order) { ... }

// ALWAYS -- stream in batches
foreach (Order::find()->batch(500) as $batch) {
    foreach ($batch as $order) { ... }
}
// or row-by-row:
foreach (Order::find()->each(500) as $order) { ... }
```

### N+1 on ActiveRecord relations
```php
// NEVER -- relation accessed inside loop triggers N queries
foreach (Order::find()->all() as $order) {
    echo $order->user->email;   // 1 query per order
}

// ALWAYS -- eager-load with ->with()
foreach (Order::find()->with('user')->each(500) as $order) {
    echo $order->user->email;   // 2 queries total
}
```

### Pagination on list endpoints
See `php.md` Bounded Queries section. Additionally for Yii2:
`ActiveDataProvider` must set `pagination.pageSize` (never `false` unless
explicitly bounded by a WHERE clause).

---

## Logging / Targets

### No DbTarget for trace/profile/info in production
```php
// NEVER in prod -- DbTarget on chatty levels writes one row per log call
'log' => [
    'targets' => [
        ['class' => 'yii\log\DbTarget',
         'levels' => ['error', 'warning', 'info', 'trace', 'profile']],
    ],
],

// ALWAYS -- FileTarget for chatty levels, DbTarget only for error/warning
'log' => [
    'targets' => [
        ['class' => 'yii\log\FileTarget',
         'levels' => ['info', 'trace', 'profile']],
        ['class' => 'yii\log\DbTarget',
         'levels' => ['error', 'warning']],
    ],
],
```

### `flushInterval` tuned for request volume
Default `flushInterval = 1000` triggers a flush every 1000 messages. High-traffic
endpoints should set it to 100-500 to avoid memory accumulation.

---

## Asset / View

### `assetManager.forceCopy` off in production
```php
// NEVER in prod -- copies assets on every request
'assetManager' => ['forceCopy' => true],

// ALWAYS in prod -- copy once, then serve cached
'assetManager' => ['forceCopy' => false, 'linkAssets' => true],
```

### View caching for expensive fragments
```php
// Wrap expensive widget renders with fragment cache
if ($this->beginCache('leaderboard', ['duration' => 300])) {
    echo Leaderboard::widget(['limit' => 100]);
    $this->endCache();
}
```

---

## Runtime (D11 for PHP)

- **opcache enabled** in production (`opcache.enable=1`, `opcache.memory_consumption>=256`)
- **opcache.validate_timestamps=0** in prod (requires deploy-time reset)
- **JIT** (`opcache.jit=tracing`, `opcache.jit_buffer_size>=100M`) for PHP 8.0+
- **PHP-FPM pool tuning:** `pm=dynamic` with `pm.max_children` sized to RAM,
  `pm.max_requests=500-1000` to recycle workers and bound memory leaks
- **No `display_errors=1`** in prod (perf + security)

---

## Detection Signals

| File / Pattern | Confirms |
|----------------|----------|
| `composer.json` has `yiisoft/yii2` | Yii2 project |
| `config/web.php`, `config/main.php` | Classic layout |
| `environments/` with `index.php` per env | yii2-app-advanced |
| `Yii::$app->db`, `Yii::$app->cache` | Running Yii2 |
| `::find()->all()`, `->batch()`, `->each()` | ActiveRecord in use |
