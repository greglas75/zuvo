#!/usr/bin/env bash
# shared/includes/model-registry.sh — SINGLE SOURCE OF TRUTH for the concrete AI model IDs the zuvo
# shell scripts pass to each provider CLI. Bump a model HERE when a new generation ships, instead of
# hunting hardcoded ids across scripts — that scatter is exactly how claude-sonnet-4-6 went a full
# generation stale (2026-07). Every value is env-overridable: an already-set ZUVO_MODEL_* wins.
#
# NOT for skill dispatch. skills/*.md use ABSTRACT tier labels (`model: sonnet|opus|haiku`) that the
# harness resolves to the current model at runtime — those need no registry and MUST stay abstract.
# This file is only for scripts that must name a concrete model id/string to a CLI (agy/codex/claude/
# cursor/gemini-api).
#
# Sourced by: adversarial-review.sh, benchmark.sh, reviewer-model-route.sh, blind-audit-codex.sh.
# Consumers ALSO keep an inline `:-<id>` fallback, so a missing/unsourced registry never breaks a run.
#
# Path: siblings `scripts/` and `shared/includes/` are copied together into every target (Claude
# cache, ~/.codex, ~/.cursor, ~/.gemini/antigravity), so a consumer resolves this as
# `"$(dirname "$0")/../shared/includes/model-registry.sh"` in all of them.

# ── Anthropic (Claude) ──────────────────────────────────────────────
ZUVO_MODEL_CLAUDE_OPUS="${ZUVO_MODEL_CLAUDE_OPUS:-claude-opus-5}"
ZUVO_MODEL_CLAUDE_SONNET="${ZUVO_MODEL_CLAUDE_SONNET:-claude-sonnet-5}"
ZUVO_MODEL_CLAUDE_HAIKU="${ZUVO_MODEL_CLAUDE_HAIKU:-claude-haiku-4-5-20251001}"

# ── OpenAI (Codex) ──────────────────────────────────────────────────
# gpt-5.6 family (GA 2026-07-09): Sol=flagship, Terra=mid, Luna=fast. Benchmarked 2026-07-19
# on identical planted-bug review @ medium: sol 18s/5 findings (most complete), terra 15s/4,
# luna 13s/3 — all caught the bug. Requires codex CLI ≥0.144 (0.142 rejects 5.6 ids).
#
# THE 5.4 FAMILY IS GONE FROM THIS ACCOUNT, measured 2026-09-09 (codex-cli 0.144.6, one probe
# per id, `codex exec --model <id>` asking for 6+7):
#   gpt-5.4 / gpt-5.4-mini / gpt-5.5-mini -> HTTP 400 "not supported when using Codex with a
#                                            ChatGPT account". Not a transient outage: the same
#                                            body came back for 206 consecutive review runs
#                                            (~/.zuvo/adversarial.log) while the lane kept being
#                                            sampled, because a 400 with the refusal in the BODY
#                                            lands as "empty", not as an auth error.
#   gpt-5.5 / gpt-5.6-sol / gpt-5.6-terra / gpt-5.6-luna -> answer normally.
#   gpt-6-astra -> 400 "requires a newer version of Codex" — worth knowing because that is what
#                  ~/.codex/config.toml pins as the host model, i.e. the HOST cannot run it
#                  through this CLI either.
# So every lane below names an id that was proven to answer on this account TODAY. When one of
# these starts refusing, re-probe before re-pinning: the failure is per-account, not per-CLI.
ZUVO_MODEL_CODEX_PRIMARY="${ZUVO_MODEL_CODEX_PRIMARY:-gpt-5.6-sol}"  # codex-5.3 lane (spark) + strong tier
# codex-5.4 lane (host-flip). The LANE NAME is historical and deliberately left alone — it is a
# token in ~/.zuvo/adversarial.log, in tests and in --provider arguments, so renaming it would
# break every measurement built on it. What changed is the id it resolves to: gpt-5.5, which is a
# different GENERATION from the primary (better cross-model spread for an adversarial second
# opinion than sol's same-family siblings terra/luna would give).
ZUVO_MODEL_CODEX_ALT="${ZUVO_MODEL_CODEX_ALT:-gpt-5.5}"
# Small/fast tier — what the Codex build resolves an abstract `haiku` agent to. gpt-5.4-mini used
# to sit here and is refused by this account, so a `haiku` sub-agent in the Codex distribution was
# being handed a model that cannot run. Luna is the fast member of the current family.
ZUVO_MODEL_CODEX_SMALL="${ZUVO_MODEL_CODEX_SMALL:-gpt-5.6-luna}"
# The alternate review lane, kept as its own name because callers and tests set it, but it now
# DERIVES from the lane above instead of carrying a fourth literal. Previously it held gpt-5.5
# independently, which is how the ALT lane could rot to a dead id while this one stayed alive.
ZUVO_MODEL_CODEX_REVIEW_ALT="${ZUVO_MODEL_CODEX_REVIEW_ALT:-$ZUVO_MODEL_CODEX_ALT}"

# ── Google (Gemini) ─────────────────────────────────────────────────
# Flash, not Pro — reversed 2026-09-01 on measurement, and the reasoning that put Pro
# here is preserved below because it was CORRECT WHEN WRITTEN and only a newer model
# retired it.
#
# The old pin cited a 2026-08-07 result (8 uncovered defensive paths a same-model audit
# called CLEAN) run on Pro (High), and noted that `agy models` "tops out at 3.1 for the
# Pro tier — 3.5/3.6 exist only as Flash". Both statements were true. 3.7 Flash shipped
# after that measurement, so the comparison it rested on no longer describes the choice.
#
# Measured 2026-09-01, same 20 real review diffs through the same prompt, both lanes:
#   3.7 Flash (High)  20/20 answered, 64s avg, 69 REAL findings, 82% precision
#   3.1 Pro   (High)   7/20 answered, 225s avg (12 timeouts + 1 empty) — and that is
#                      WITH DEFAULT_TIMEOUT already raised to 400s (cb913be)
# A size ladder (one diff cut to 5/12/20/28 kB, 2 reps each) shows why: Pro's wall clock
# scales 4.6x with input size (52s -> 239s) and crosses the timeout at ~20 kB, while Flash
# stays flat at 60-90s. The fleet log agrees — in the 15-30 kB band, 54% of all runs, the
# Pro lane failed to answer 52% of the time.
# An Opus judge also caught Pro reviewing the production file named in a diff HEADER
# instead of the artifacts actually in the diff — a correctness fault, not just latency.
#
# A reviewer that does not answer has precision 0, whatever it scores when it does.
# Display name, exactly as `agy models` prints it: a wrong string fails silently.
#
# 3.8 Flash (High) since 2026-09-05, on measurement: the same 20 review diffs through both,
# every finding judged REAL/FALSE_POSITIVE by an independent Opus judge against the diff,
# with a shared defect vocabulary so neither model scores twice for one defect.
# The decisive number is MARGINAL coverage over the other six providers, not the head-to-head:
#   others alone 215 defects · +3.7 Flash 232 (17 unique) · +3.8 Flash 247 (32 unique)
# 3.8 nearly doubles what this lane contributes that nobody else finds. It is bought with
# three real regressions, all measured, none disqualifying for an ADVERSARIAL reviewer where
# a false positive dies in triage and a missed defect ships:
#   precision 82% -> 73%   (30 false positives vs 15)
#   median 66s -> 172s, p90 273s, max 308s against the 400s PROVIDER_TIMEOUT
#   1/20 empty answer, plus 2/20 returning zero findings — one of them a diff in which the
#   other providers found 37 real defects and 3.7 found 6. 3.8 is streakier, not just slower.
# Running BOTH was measured and rejected: +9 defects over 3.8 alone for two of the five
# provider slots spent on one vendor, and cross-VENDOR spread is where the coverage comes from.
#
# 3.8 Flash (Medium) since 2026-09-23 — effort sweep, all three levels run the SAME day on the
# same 20 diffs with the same Opus judge (a fresh High run included, not the 09-05 number):
#                 unique over others  precision  REAL  avg/diff  timeouts (500s)
#   Low                 14               56%       48     28s        0
#   Medium              25               75%       86    148s        0
#   High                21               71%       82    167s        2
# The same High config measured +32 on 09-05 and +21 today: run-to-run noise is ~±10, so
# Medium is NOT proven better than High — it is not worse, and it never timed out while High
# lost the same diff to the 500s ceiling three times out of three. Low is ruled out: it finds
# half as much and 44% of what it reports is false.
ZUVO_MODEL_AGY="${ZUVO_MODEL_AGY:-Gemini 3.8 Flash (Medium)}"
# Same value as the default. High is not deeper in what the set gains (see the sweep above) and
# is the level that times out, so pointing the DEEP lane at it would buy non-answers exactly
# where a caller asked for more depth. 3.1 Pro was ruled out for the same reason (65% non-answer).
ZUVO_MODEL_AGY_DEEP="${ZUVO_MODEL_AGY_DEEP:-Gemini 3.8 Flash (Medium)}"
# FALLBACK, used only when the primary model above is out of quota. Antigravity meters each
# model separately — verified 2026-09-22, Gemini exhausted for the week while the others
# answered in 15-25s — so a dead model here is not a dead lane, and before this existed the
# lane simply hung ~160s per chunk and returned nothing (5/5 real reviews on 2026-09-21).
#
# Why Opus 4.6 and not the cheaper two. All three benched on the SAME 20 diffs as the rest of
# the field, judged by Opus against a shared defect vocabulary:
#   Claude Opus 4.6 (Thinking)    65% precision, +12 new defects   (11/20 — quota, not the model)
#   Claude Sonnet 4.6 (Thinking)  39% precision, +7   (19/20) — 9 false alarms per unique defect
#   GPT-OSS 120B (Medium)         22% precision, +8   (15/20) — worst of the whole field
# Sonnet and GPT-OSS are deliberately NOT a second and third rung: below ~40% precision a
# reviewer costs more triage than the coverage it adds, and this lane already has a standing
# alternative in the other providers.
#
# It is a FALLBACK, never a lane: measured 2026-09-22, ~12 calls exhaust its 5-hour allowance
# (11 consecutive ok, then the wall, in 37 minutes) against a fleet that ran 640 agy calls in a
# day. That is fine for the handful of chunks one review needs and hopeless as a standing slot.
# Set ZUVO_AGY_FALLBACK_MODEL="" to disable the fallback entirely.
ZUVO_MODEL_AGY_FALLBACK="${ZUVO_MODEL_AGY_FALLBACK-Claude Opus 4.6 (Thinking)}"
ZUVO_MODEL_GEMINI_API="${ZUVO_MODEL_GEMINI_API:-gemini-3.1-pro-preview}"  # gemini-api curl fallback (needs GEMINI_API_KEY)

# ── OpenRouter (paid, opt-in) ───────────────────────────────────────
# Two models, chosen by measurement, not by benchmark rank. 20 real review diffs, every
# finding judged REAL / FALSE_POSITIVE / UNVERIFIABLE by an independent Opus judge against
# the diff, with a shared defect-id vocabulary so overlapping findings collapse:
#   z-ai/glm-5.3        85 REAL /  1 FP (99%) — adds 32 defects nothing free covers, 363s, $2.92/20
#   qwen/qwen3.8-flash  80 REAL /  2 FP (98%) — adds 22, 336s, $0.26/20
# Both fit under DEFAULT_TIMEOUT=400.
#
# What the same measurement REJECTED, so nobody re-adds them on price or speed:
#   qwen/qwen3-coder-next  25% precision, 66 false positives — the cheapest ($0.04/20) and
#                          fastest (16s) model in the whole field, and almost pure fabrication.
#                          Zero reasoning tokens; it does not analyse, it pattern-matches.
#   poolside/laguna-s-2.1  35%, 46 FP — same shape, same trap.
#   minimax/minimax-m3     62% under an Opus judge vs 84% under a Sonnet one. Weak-judge
#                          artifact; it reads convincingly and is wrong.
# The lesson those three encode: findings COUNT is a gadfly metric. A model that emits five
# plausible paragraphs per diff outranks a careful one until somebody checks the claims.
# CZTERY lane'y OpenRoutera, wybrane 2026-09-09 z pomiaru 19 modeli na tych samych 20 diffach
# (wspolny slownik defektow, sedzia Opus). Kolumna, ktora decydowala, to NOWE defekty ponad
# darmowy zestaw — ten sam znajduje 154 i placenie za ich powtorzenie jest bezwartosciowe.
#
#   lane            model                          nowe  prec   czas   $/wywolanie
#   openrouter      qwen/qwen3.8-flash               30   98%   336s   0.0331
#   openrouter-alt  deepseek/deepseek-v4-flash       13   80%   309s   0.0241
#   openrouter-3    inception/mercury-2.5-preview    13   28%     8s   0.0007
#   openrouter-4    openai/gpt-oss-120b              13   32%    79s   0.0008
#
# Dwa pierwsze to jakosc (98% i 80% precyzji — najwyzsze w calej stawce), dwa ostatnie to
# pokrycie za grosze: kazdy dokłada 13 defektow, ktorych darmowy zestaw nie widzi, po cenie
# ponizej jednej dziesiatej centa. Ich precyzja 28-32% jest zla, ale falszywka ginie przy
# triazu, a przeoczony defekt jedzie na produkcje — przy recenzencie ADVERSARIAL ta asymetria
# uzasadnia szum, ktorego nie uzasadnialaby w zadnym innym miejscu.
#
# Oba pierwsze wymagaja limitu >=500s: mierzone srednie 336s i 309s przy suficie 450s to byla
# ruletka, a nie margines. Limit podniesiony razem z tym wyborem (patrz DEFAULT_TIMEOUT).
#
# Odrzucone mimo dobrych liczb: glm-5.3 (38 nowych, 99% precyzji — najlepszy recenzent w
# stawce, ale $0.134 za wywolanie w produkcji i 31% wywolan gineło na suficie, wiec ponad
# jedna trzecia rachunku kupowala cisze) oraz muse-spark-1.3 (23 nowe, byl tu do 09-09).
# Odrzucone jako szkodliwe: gemini-2.5-flash-lite (118 falszywek na 13 trafien, precyzja 10%)
# i gemini-3.5-flash-lite (11 z 20 review zakonczonych "czysto" w 3 sekundy na diffach, ktore
# defekty MAJA — to nie szybkosc, to odmowa pracy).
#
# Lane jest wlaczany flaga ZUVO_ADV_OPENROUTER=1 (platny, wiec nigdy sama obecnoscia klucza).
ZUVO_MODEL_OPENROUTER="${ZUVO_MODEL_OPENROUTER:-qwen/qwen3.8-flash}"
ZUVO_MODEL_OPENROUTER_ALT="${ZUVO_MODEL_OPENROUTER_ALT:-deepseek/deepseek-v4.1-flash}"  # 2026-09-16: vision-exp delivered 51% @308 s (benched); v4.1-flash landed on OpenRouter 09-10, after the lane benchmark
ZUVO_MODEL_OPENROUTER_3="${ZUVO_MODEL_OPENROUTER_3:-inception/mercury-2.5-preview}"
ZUVO_MODEL_OPENROUTER_4="${ZUVO_MODEL_OPENROUTER_4:-openai/gpt-oss-120b}"

# ── BytePlus ModelArk Coding Plan (prepaid, opt-in via ZUVO_ADV_BYTEPLUS=1) ──
# A SUBSCRIPTION, not a meter. Two consequences that shape everything below:
#   * a review costs nothing extra until the plan's quota is spent, and then it hard-stops —
#     "Other packages or account balances will not be consumed" (vendor FAQ). No surprise bill.
#   * the quota is SHARED with whatever else points at the plan (the owner's own Claude Code,
#     Cursor, …), which is why the lane is opt-in even though it is already paid for.
#
# THE BASE URL IS A BILLING DECISION, not a detail. The same key works on both:
#   https://ark.ap-southeast.bytepluses.com/api/coding/v3   consumes the plan   <- use this
#   https://ark.ap-southeast.bytepluses.com/api/v3          bills the balance   <- never
# run_openrouter refuses any bytepluses.com/volces.com URL that is not the /api/coding path,
# because one wrong character would meter every chunk of every review in silence.
ZUVO_BYTEPLUS_BASE_URL="${ZUVO_BYTEPLUS_BASE_URL:-https://ark.ap-southeast.bytepluses.com/api/coding/v3}"
# glm-5.3-flash: 95% precision and +18 defects nobody else in the set finds — the best reviewer
# measured after Gemini 3.8 Flash, on the same 20 diffs and the same Opus judge as the rest of
# this file. On OpenRouter the identical model is $0.15/$0.50 per 1M; here it is inside the plan.
ZUVO_MODEL_BYTEPLUS="${ZUVO_MODEL_BYTEPLUS:-glm-5.3-flash}"
# deepseek-v4-flash: a second VENDOR family in the same plan, which is where cross-model
# coverage actually comes from. (The benched sibling deepseek-v4-pro scored 64%/+6; the flash
# variant is the one the plan lists and is not yet benched here — measure before promoting it
# past the alt slot.)
ZUVO_MODEL_BYTEPLUS_ALT="${ZUVO_MODEL_BYTEPLUS_ALT:-deepseek-v4-flash}"
# Verified 2026-09-22 against the live plan: glm-5.3-flash 7s, deepseek-v4-flash 5s.
# 'ark-code-latest' is REJECTED as UnsupportedModel on this plan — name a concrete model.

# ── Cursor ──────────────────────────────────────────────────────────
# auto, nie composer: `composer-2.5-fast` ZNIKNAL z `cursor-agent models` (jest tylko
# `composer-2.5`), a konto ma wyczerpany limit — "You're out of usage. Switch to Auto".
# Lane zwracal PUSTO w 281 przebiegach od 2026-09-06 i nadal zajmowal slot, bo pusta
# odpowiedz nie zasila bufora wykluczen (ten lapie tylko bledy logowania).
# `auto` odpowiada normalnie przy tym samym koncie — zweryfikowane 2026-09-09.
ZUVO_MODEL_CURSOR="${ZUVO_MODEL_CURSOR:-auto}"

# ── Moonshot (Kimi) ─────────────────────────────────────────────────
ZUVO_MODEL_KIMI_CLI="${ZUVO_MODEL_KIMI_CLI:-}"                       # kimi CLI -m alias; EMPTY = use the CLI's own default (kimi-code/k3, OAuth) — verified E2E 2026-07-19
ZUVO_MODEL_KIMI="${ZUVO_MODEL_KIMI:-kimi-k2.6}"                      # kimi-api curl fallback (needs MOONSHOT_API_KEY); k2.7-code = coding variant, same price
