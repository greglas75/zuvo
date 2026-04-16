# Banned Vocabulary Loader

> Compatibility index for `write-article` and `content-expand`. The monolithic list has been split into a shared core plus per-language files so agents only load the active language.

## Load Order

Always load in this order:

1. `./banned-vocabulary/core.md`
2. `./banned-vocabulary/languages/<resolved-lang>.md`
3. Fallback: `./banned-vocabulary/languages/en.md` if `<resolved-lang>` is missing

## Language Resolution

- Normalize to lowercase base code before lookup: `pt-BR -> pt`, `fr-CA -> fr`, `de-AT -> de`
- Collapse script or region variants to their shared file: `zh-CN -> zh`, `zh-TW -> zh`, `sr-Latn -> sr`
- If unsupported, emit a warning and fall back to English

## Supported Language Files

`ar`, `bg`, `cs`, `da`, `de`, `el`, `en`, `es`, `et`, `fi`, `fr`, `hr`, `hu`, `id`, `it`, `ja`, `ko`, `lt`, `lv`, `nl`, `no`, `pl`, `pt`, `ro`, `sk`, `sl`, `sr`, `sv`, `th`, `uk`, `vi`, `zh`

## Coverage Notes

- `en` and `pl` remain the most mature lists.
- All other languages currently use conservative seed lists. Expand them when corpus evidence shows stable local slop patterns.
- Shared rules like tone handling, burstiness, and G12 anti-patterns live in `core.md`, not in language files.
- Coverage tiers and minimum per-language list sizes live in `./banned-vocabulary/registry.tsv`.
