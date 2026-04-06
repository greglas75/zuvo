# SEO Bot Registry

> Single source of truth for bot keys used by `seo-audit`, `seo-fix`, and SEO
> website claim validation.
> Use `bot_key` values from this file in `bot_matrix[]`, `bot_scope[]`, live
> verification output, and deterministic robots policy templates.

## Conventions

- `tier` is one of `training`, `search`, `retrieval`, or `user-proxy`.
- `default_recommendation` is a suggestion for a conscious default, not a
  mandatory ideology. Users may intentionally choose a different policy.
- `live_probe_required` indicates whether the suite should attempt user-agent
  verification in `--live-url` mode.
- `cloudflare_sensitive` marks bots commonly affected by Cloudflare AI crawler
  or bot-management controls.

## Registry

| bot_key | user_agent | provider | tier | default_recommendation | live_probe_required | cloudflare_sensitive | notes |
|---------|------------|----------|------|------------------------|---------------------|----------------------|-------|
| `gptbot` | `GPTBot` | OpenAI | training | disallow | yes | yes | Training crawler; separate from user-facing ChatGPT fetchers. |
| `claudebot` | `ClaudeBot` | Anthropic | training | disallow | yes | yes | Training crawler for Anthropic corpus collection. |
| `google-extended` | `Google-Extended` | Google | training | disallow | yes | yes | Controls Gemini and AI training consent separately from standard Googlebot. |
| `ccbot` | `CCBot` | Common Crawl | training | disallow | yes | no | Crawl corpus often reused downstream by other data consumers. |
| `bytespider` | `Bytespider` | ByteDance | training | disallow | yes | yes | ByteDance/TikTok crawler family. |
| `meta-externalagent` | `Meta-ExternalAgent` | Meta | training | disallow | yes | yes | Meta external collection agent; high policy sensitivity. |
| `applebot-extended` | `Applebot-Extended` | Apple | training | disallow | yes | yes | Extended Apple agent for AI/training-style access. |
| `oai-searchbot` | `OAI-SearchBot` | OpenAI | search | allow | yes | yes | Search crawler for OpenAI answer products. |
| `claude-searchbot` | `Claude-SearchBot` | Anthropic | search | allow | yes | yes | Search crawler for Anthropic answer experiences. |
| `perplexitybot` | `PerplexityBot` | Perplexity | search | allow | yes | yes | Search bot used for indexed retrieval and answer generation. |
| `googleother` | `GoogleOther` | Google | retrieval | allow | yes | no | General retrieval-oriented Google crawler distinct from classic Search indexing. |
| `amazonbot` | `Amazonbot` | Amazon | retrieval | allow | yes | yes | Retrieval crawler used across Amazon surfaces. |
| `chatgpt-user` | `ChatGPT-User` | OpenAI | user-proxy | allow | yes | yes | User-triggered fetches on behalf of a human ChatGPT session. |
| `claude-user` | `Claude-User` | Anthropic | user-proxy | allow | yes | yes | User-triggered fetches on behalf of a human Claude session. |
| `perplexity-user` | `Perplexity-User` | Perplexity | user-proxy | allow | yes | yes | User-triggered fetches on behalf of a human Perplexity session. |

## Policy Notes

- The recommended conscious default is usually `disallow` for `training` and
  `allow` for `search`, `retrieval`, and `user-proxy`.
- `seo-audit` should verify consciousness and consistency, not enforce a single
  worldview.
- `seo-fix` should use this registry to generate deterministic robots policy
  sections and to decide which bots are eligible for live user-agent probing.
