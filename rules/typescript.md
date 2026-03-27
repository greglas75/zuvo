# TypeScript Conventions

Active when the project contains TypeScript files or `tsconfig.json`. Not applicable to pure Python or non-TS projects.

---

## Eliminating `any`

```typescript
// NEVER — use `unknown` or proper types instead
catch (err: unknown) {
  const message = err instanceof Error ? err.message : String(err);
}

// NEVER — `as any` casts mask type errors. Extend interfaces or use generics.
// NEVER — implicit `any` from untyped parameters or returns. Always annotate.
```

When modifying a file that contains `any`: fix the `any` types in the code you touch. Do not leave them.

## Schema-First Types (Zod)

When the project uses Zod, define schemas first and derive types from them. The schema is the source of truth.

```typescript
// CORRECT — schema defines shape, type is inferred
export const UserSchema = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  role: z.enum(["admin", "user"]),
});
export type User = z.infer<typeof UserSchema>;

// WRONG — manual interface duplicates what the schema already defines
interface User { id: string; email: string; role: string; }
```

## Explicit and Strict Typing

```typescript
// Annotate return types on all public functions
async function fetchUsers(): Promise<User[]> { ... }

// Model complex states with discriminated unions
type RequestState<T> =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "success"; data: T }
  | { status: "error"; error: Error };

// Never leave variables untyped
const data: any = await fetch(); // WRONG
const data: unknown = await fetch(); // then validate/parse
```

## Error Handling in TypeScript

Catch blocks must use `unknown` and narrow with `instanceof` before accessing `.message`. Never cast with `as Error`. See `cq-patterns.md` for full pattern.

## Constants Over Enums

```typescript
// Prefer const objects or union types
const STATUS = { ACTIVE: "active", INACTIVE: "inactive" } as const;
type Status = (typeof STATUS)[keyof typeof STATUS];

// Simple union types work well for small sets
type Direction = "up" | "down" | "left" | "right";
```

## Constrained Generics

```typescript
// Constraints make generics meaningful
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key];
}

// Unconstrained generics are `any` in disguise
function bad<T>(x: T): T { return x; } // Too loose
```

## Type-Only Imports

```typescript
// Separate type imports for better tree-shaking
import type { User, UserSchema } from "./types";
import { validateUser } from "./validation"; // runtime import
```
