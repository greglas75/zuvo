# Edge Case Checklist

> Apply per parameter type for STANDARD and COMPLEX files. THIN wrappers skip this checklist — test wiring correctness and error propagation only.

| Parameter Type | Edge Cases to Test |
|---------------|-------------------|
| **string** | empty `""`, whitespace `"  "`, unicode `"日本語"`, max-length, single char |
| **number** | `0`, negative, `NaN`, `Infinity`, `Number.MAX_SAFE_INTEGER`, float precision |
| **array** | empty `[]`, single element, duplicates, very large (1000+), sparse |
| **object** | empty `{}`, missing keys, extra keys, null prototype `Object.create(null)` |
| **boolean** | explicit `true`/`false`, truthy/falsy coercion traps (`0`, `""`, `null`) |
| **Date** | invalid date, epoch (`new Date(0)`), timezone edge (DST transitions), far future |
| **optional** | `undefined`, `null`, missing key vs present-null, explicit `undefined` in object |
| **enum** | each valid value, invalid value not in enum, `undefined` |
