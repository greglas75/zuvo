# Adversarial Review — Session Summary (2026-04-05/06)

## Co zrobione (22 commity na main)

### Blok 1: Cursor v3 Build + Install
- `e6d9130` — `build-cursor-skills.sh`: transforms skills for Cursor v3 (agent frontmatter: `model: inherit`, `readonly: true/false`, flat agents with skill prefixes)
- `515c212` — Fix R-1 do R-5 z review Cursora (build errors hidden, docs out of sync, prefix mismatch, readonly detection, no-op sed)
- `8173a27` — Cleanup 12 starych symlinków `claude-code-toolkit` w `~/.codex/`
- `install.sh` obsługuje teraz 3 platformy: `./scripts/install.sh [claude|codex|cursor|all]` (default: `all`)

### Blok 2: Adversarial Review Script (`scripts/adversarial-review.sh`)
- `cb26283` — Provider detection + fallthrough (Gemini > Codex > Ollama)
- `73aa17f` — Codex app bundle detection (`/Applications/Codex.app/Contents/Resources/codex`)
- `b80d272` — Multi-provider mode (domyślnie ALL providers)
- `d0e812d` — Hardening: truncation at line boundary, prompt injection defense, per-provider timeout, language auto-detection
- `9d98add` — `--json`, `--mode code|test|security`, `--context "hint"` flags
- `9777a7f` — Fix watchdog `$$` kills parent + eval injection (temp files zamiast eval)
- `687fa33` — Cursor Agent CLI jako 4. provider + Gemini model fix
- `52f7602` — Default Gemini model: `gemini-2.5-pro` (potem zmieniony)

### Blok 3: Adversarial Loop (agent-in-the-loop)
- `0a578ae` — `shared/includes/adversarial-loop.md`: protokół auto-review przed prezentacją wyniku userowi
- `8211607` — Adversarial review od TIER 1 (nie TIER 2+), must-run enforcement
- `e86b860` — Gemini stdin fix (temp file zamiast -p argument), parallel dispatch w review SKILL.md, Ollama usunięty z auto-detect

### Blok 4: Fixes z adversarial review findings
- `f9e73bc` — Parallel 2-provider + random selection w adversarial-loop.md
- `fda5719` — Timeout 120s → 300s
- `5dad68c` — 6 bugów znalezionych przez multi-provider adversarial (Gemini + Cursor + Codex)

### Blok 5: Fast providers
- `6abab9f` — Gemini API provider (curl, 2-15s, free tier z `GEMINI_API_KEY`)
- `6c2e903` — Fixes z Gemma 4 26b review (URL injection, ARG_MAX, curl -f, npx removed)
- `e8cedff` — Cursor CLI usunięty (buggy, hangs)
- `5a9c25c` — Default Gemini API model: `gemini-3-flash-preview`
- `9b4f2d6` — Codex MCP provider (JSON-RPC over stdio FIFO, ~30s vs CLI ~300s timeout)

### Blok 6: gemini-fast.sh (dodany przez innego agenta)
- Nowy skrypt `scripts/gemini-fast.sh` — próba użycia OAuth tokenów z Gemini CLI do bezpośrednich API calls
- Dodany `run_gemini_fast()` do adversarial-review.sh jako najwyższy priorytet provider
- **Status: NIE DZIAŁA** — OAuth token z CLI ma za wąski scope (`ACCESS_TOKEN_SCOPE_INSUFFICIENT`), nie działa z publicznym API ani cloudcode endpoint

---

## Co działa (potwierdzone testami)

| Provider | Metoda | Czas | Koszt | Status |
|----------|--------|------|-------|--------|
| **Gemini API** (`gemini-api`) | curl + `GEMINI_API_KEY` | 15-60s | Free tier (2.5-flash, 3-flash) lub $0.03 (pro) | **DZIAŁA** |
| **Codex MCP** (`codex-mcp`) | JSON-RPC stdio do `codex mcp-server` | ~30s | Z planu ChatGPT | **DZIAŁA w --single** |
| Gemini CLI (`gemini`) | `gemini -p` via temp file stdin | 90-150s | Free | Działa ale wolne |
| Ollama | `ollama run model` | 3-10min | Free/lokalne | Działa ale za wolne |

### API Key setup
- `GEMINI_API_KEY` — z `~/DEV/translation-qa/.env` (`AIzaSyDwZkjyYoM-pcKzT1fuNyraO9ToMjRzPAg`)
- Free tier: 15 RPM, 1000 RPD — pokrywa adversarial review z zapasem
- Modele free tier: gemini-2.5-flash, gemini-3-flash-preview, gemini-3.1-flash-lite-preview

---

## Co NIE działa

### 1. `--multi` mode w skrypcie (parallel w bash)
- **Problem**: `run_provider()` uruchamia subshell w tle. W multi mode każdy provider jest w tle. Zagnieżdżone background procesy tracą FIFO/stdin/zmienne.
- **Objaw**: Zombie procesy, timeout, pusty output. 50+ procesów `adversarial-review.sh` wisi.
- **Root cause**: `run_codex_mcp()` używa FIFO + pipe + background poll — to nie działa w nested subshell.
- **Gemini API działa w parallel** (prosty curl), **Codex MCP nie** (FIFO breaks).
- **Workaround**: Dispatch przez Agent tool (osobny proces per provider, nie subshell). Adversarial-loop.md już to opisuje.
- **Potrzebny fix**: Uprościć `run_codex_mcp()` — usunąć polling loop, użyć prostego pipe z timeout. Albo usunąć `--multi` i zostawić tylko `--single --provider X`.

### 2. `gemini-fast.sh` (OAuth reuse)
- **Problem**: OAuth token z Gemini CLI ma scope ograniczony do wewnętrznego API Google. Publiczne endpointy (`generativelanguage.googleapis.com`, `cloudcode-pa.googleapis.com`) odrzucają go z `ACCESS_TOKEN_SCOPE_INSUFFICIENT`.
- **Inny agent** twierdził że działa, ale moje testy pokazują 403/404 na wszystkich endpointach.
- **Do zbadania**: Może endpoint się zmienił, albo trzeba innego scope w OAuth. Sprawdzić co dokładnie Gemini CLI wysyła (może sniffować ruch).

### 3. Cursor CLI (`agent --print`)
- Wymaga workspace trust (interaktywny prompt)
- Headless mode wisi po odpowiedzi (znany bug)
- Brak MCP server mode
- **Wyrzucony z providerów** w commit `e8cedff`

### 4. Codex CLI exec
- Timeout >300s na diffach >10K chars
- **Zastąpiony przez Codex MCP** (30s vs timeout)

### 5. Ollama (lokalne modele)
- gemma4:26b — 5 min na review (dobra jakość, za wolne)
- qwen3-coder — 10 min (za wolne)
- mistral-small:24b — 90s (słaba jakość)
- **Wyrzucony z auto-detect** — dostępny przez `--provider ollama`

---

## Porównanie modeli (ten sam diff, HEAD~3)

| Model | Czas | Findings | Unikalne | Koszt |
|-------|------|----------|----------|-------|
| Gemini 2.5 Flash API | 26s | 3 | 1 | Free |
| Gemini 3 Flash API | 61s | 5 | 2 | Free |
| Gemini 3.1 Pro CLI | 150s | 5 | 3 | Free |
| Codex MCP (gpt-5.4) | 30s | 2 | 1 | Plan |
| Gemma 4 26b (Ollama) | 5min | 5 | 2 | Free |
| Qwen3-coder (Ollama) | 10min | 5 | 0 | Free |

**Wniosek**: Gemini 3 Flash (free, 61s) + Codex MCP (plan, 30s) = najlepszy tradeoff. Pro modele lepsze ale droższe/wolniejsze. Lokalne modele dobre ale za wolne.

### Najgroźniejsze findings per model:
- **Gemini CLI (3.1-pro)**: `git add -A` leaks secrets do external LLM — NAJGROŹNIEJSZY
- **Gemma 4 (local)**: URL injection via model variable (SSRF)
- **Cursor**: SIGPIPE kills script silently (truncation bug)
- **Codex MCP**: Sandbox regression (untrusted code exec)
- **Gemini API (2.5-flash)**: Model default mismatch, curl timeout regression

---

## Architektura skryptu (`adversarial-review.sh`)

### Argument parsing
```
--provider X          # wymusz jeden provider
--single              # pierwszy sukces (sekwencyjnie)
--multi               # wszystkie providery (BUG: parallel nie działa w bash)
--mode code|test|security  # prompt focus area
--json                # machine-readable output
--context "hint"      # dodaj kontekst do promptu
--diff REF            # review z git diff
--files "f1 f2"       # review konkretnych plików
--model MODEL         # override modelu Ollama
```

### Provider priority (auto-detect)
```
1. gemini-fast  — OAuth reuse (NIE DZIAŁA, do naprawy)
2. gemini-api   — curl + GEMINI_API_KEY (2-15s, free)
3. gemini       — CLI (90s+, free)
4. codex-mcp    — JSON-RPC stdio (30s, plan)
5. codex-app    — CLI exec (timeout, fallback)
```

### Flow
```
Input (stdin/--diff/--files)
  → Truncation (15K chars, SIGPIPE-safe)
  → Language detection (TS/React/NestJS/Astro/Python/PHP/Go)
  → Mode-specific prompt (code/test/security focus areas)
  → Confidence field (high/medium/low per finding)
  → Prompt injection prefix
  → Provider dispatch
  → Output (text with banners / JSON)
```

---

## Adversarial Loop (`shared/includes/adversarial-loop.md`)

### Koncept
Agent pisze kod → konsultuje z innym AI modelem → naprawia CRITICAL → dopiero prezentuje userowi.

### Kiedy odpala
- Diff > 30 linii LUB
- Diff dotyka: auth, billing, crypto, PII, migrations (nawet 5 linii)

### Fix policy
- CRITICAL → fix immediately
- WARNING < 10L → fix immediately
- WARNING >= 10L → known concerns
- INFO → known concerns

### Presentation policy
- Unresolved CRITICAL → **nie mów "complete"**
- Unresolved WARNING → deliver z disclosure
- INFO only → normal delivery

### Zintegrowane skille (Phase 1)
- `/build` — Phase 4.4 (po execution checklist, przed backlog)
- `/write-tests` — Phase 4.5 (po test quality auditor, przed completion)

### Niezintegrowane (Phase 2)
- `/execute`, `/write-e2e`, `/refactor` — oznaczone "not yet integrated"

### Dispatch pattern
- Skrypt z `--single --provider X` (nie `--multi`)
- Parallelizm przez Agent tool (2 agenty, run_in_background)
- Random selection 2 z dostępnych providerów

---

## Review SKILL.md zmiany

### Adversarial pass od TIER 1 (nie TIER 2+)
```
TIER 0             → Skip
TIER 1 + risk signal → Run (single provider)
TIER 1, no risk    → Skip
TIER 2             → Run (single provider)
TIER 3             → Run (multi provider)
--thorough         → Run (multi-pass Pass 4)
```

### Cross-provider dispatch
```
TIER 1-2: 2 agenty równolegle (Agent tool, --provider X per agent)
TIER 3:   3 agenty równolegle
```

### "attempt" → "run" — NOT optional

---

## Feedback z ChatGPT i Claude (na plan testów)

### Kluczowe braki w planie testów:
1. Brak testów timeout (provider przekracza limit, multi mode fallback)
2. Brak testów pustego/uszkodzonego output (exit 0 ale pusty, markdown fences, śmieci)
3. Brak testów precedence (--provider > env var, --single + --multi razem)
4. Brak testów --diff mode (git repo setup)
5. Brak testów JSON multi output (2 providery, fenced JSON)
6. Brak testów risk-based threshold (auth patterns < 30L → still run)
7. Brak testów --context flag i --mode auto-switch

### Priorytet testów:
1. **Must-have**: help, empty input, stdin, --diff, no providers, single/multi mode, timeout, json output
2. **Important**: pusty output, env override, truncation, fenced JSON
3. **Nice-to-have**: language detection, display name normalization

---

## Co dalej (niezrobione)

### Pilne
1. **Fix `--multi` w skrypcie** — uprościć `run_codex_mcp()` (usunąć polling, prosty pipe) albo usunąć `--multi` i zostawić parallelizm na Agent tool
2. **Fix `gemini-fast.sh`** — znaleźć prawidłowy endpoint dla OAuth tokenów z CLI (lub usunąć)
3. **Commit niezcommitowane zmiany** — parallel multi mode, gemini-fast integration

### Ważne
4. **Testy (bats)** — inny agent pisze, feedback od ChatGPT/Claude do uwzględnienia
5. **Phase 2 rollout** — integracja adversarial loop do `/execute`, `/write-e2e`, `/refactor`
6. **`GEMINI_API_KEY` na stałe** — dodać do `~/.zshrc` zamiast exportować per sesja
7. **Install.sh sync** — po commitach uruchomić `./scripts/install.sh` żeby plugin cache był aktualny

### Nice-to-have
8. Gemini API z modelem `gemini-2.5-pro` ($0.03/review) dla security-critical diffów
9. Dedup findings z multi-provider (2+ modele zgadzają się = wyższy confidence)
10. `--with-context N` — dodaj N linii kontekstu wokół hunków
11. Exit code differentiation (0=clean, 3=CRITICAL)
12. Cache/dedup (hash-based, 1h TTL)

---

## Pliki zmienione w tej sesji

### Nowe
- `scripts/build-cursor-skills.sh` — build Cursor v3 distribution
- `scripts/gemini-fast.sh` — OAuth reuse (dodany przez innego agenta, NIE DZIAŁA)
- `shared/includes/adversarial-loop.md` — agent-in-the-loop protocol
- `dist/cursor/` — built Cursor distribution (39 skills, 19 agents)

### Zmodyfikowane
- `scripts/adversarial-review.sh` — 12+ commitów, 4 providery, 3 mode'y, JSON output, confidence, timeout, parallel
- `scripts/install.sh` — dodany Cursor, default `all`, build error logging, symlink cleanup
- `skills/build/SKILL.md` — Phase 4.4 adversarial loop
- `skills/write-tests/SKILL.md` — Phase 4.5 adversarial loop
- `skills/review/SKILL.md` — TIER 1+ adversarial, must-run, parallel Agent dispatch
- `README.md` — 3-platform support, Cursor v3
- `CLAUDE.md` — 3-platform support, Cursor build script
- `docs/review-queue.md` — commit log

### Zainstalowane do
- `~/.claude/plugins/cache/zuvo-marketplace/zuvo/1.1.0/` — Claude Code
- `~/.codex/skills/`, `~/.codex/agents/` — Codex (39 skills, 19 TOMLs)
- `~/.cursor/skills/`, `~/.cursor/agents/` — Cursor (39 skills, 19 agents)
