# GPU-UPDATE-NOW.md — GPU Package Pricing Update

**Status:** Ready for website implementation
**Effective:** Upon publish
**Owner:** Robert
**Currency:** USD

---

## 1. Summary of Changes

| Change | Detail |
|---|---|
| Residential | Base residential packages **unchanged** — only the **CPU** portion is unlimited use; GPU is never unlimited. New optional **+6h GPU add-on** available to any residential subscriber. |
| Commercial | GPU time sold as **+8 hour packs**. Volume discount: **buy 160 hours (20 packs), get 21% off**. |
| Volume anchor | 160h volume rate = $9.38/GPU-hr — preserves the current $375/40h effective rate. |
| Guardrails | Concurrency caps, idle timeout, rate limits, pack expiry. |
| Overage policy | Throttle-first, then metered overage (commercial only). |

---

## 2. Pricing Table

### Residential — Base + Optional GPU Add-On

| Item | Value |
|---|---|
| Base residential package | Existing packages unchanged — **CPU is unlimited use** (that's the "infinite" part); GPU is NOT included by default |
| **+6 Hours GPU add-on** (optional) | **+$20 / month** |
| Effective rate | $3.33 / GPU-hr |
| Fair-use cap | 6 GPU-hrs/mo (~600M tokens worst case) |
| Concurrency | 1 session |
| Access | App-only (no raw API keys) |
| Notes | Add-on can be enabled/disabled per billing cycle; unused hours do not roll over. |

### Commercial — +8 Hour GPU Packs

| Item | Single Pack | Volume Deal |
|---|---|---|
| Pack size | 8 GPU-hours | 160 GPU-hours (20 × 8h packs) |
| Price | **$95** | **$1,500** (**21% off** — reg. $1,900) |
| Effective rate | $11.88 / GPU-hr | **$9.38 / GPU-hr** |
| Worst-case tokens | ~800M per pack | ~8B per volume deal |
| Expiry | 90 days from purchase | 90 days from purchase |
| Concurrency | 1 session | 2 sessions |
| Overage | Throttle to 50%, then $12/GPU-hr metered | Throttle to 50%, then $12/GPU-hr metered |

> **Marketing angle:** *"Buy 160 hours of +8h commercial packs, get 21% off."*
> Volume rate matches today's $375/40h pricing — existing heavy buyers pay the same per-hour, just in flexible 8h units.

### Enterprise anchor (optional listing)

| Item | Value |
|---|---|
| Dedicated GPU (sustained, ~700 hrs/mo cap) | Quote-based; contact sales |

---

## 3. Guardrails (apply to all paid tiers)

1. **Single seat per pack** — one API key/device binding; no parallel sessions beyond tier concurrency.
2. **Rate cap** — Residential add-on: 1–2K tok/s. Commercial: 3K tok/s max.
3. **Idle timeout** — sessions idle > 5–10 minutes release GPU capacity automatically.
4. **Per-session token cap** — ~100M tokens per 5-hour rolling window (abuse ceiling).
5. **Metering** — log GPU-hours + tokens per key; monthly invoice for commercial volume buyers.
6. **Overage behavior** — never a hard cliff: throttle to 50% speed first, then metered billing at $12/GPU-hr.

---

## 4. Rationale (for pricing page FAQ)

- **+6h residential add-on** is opt-in — median residential user never needs it, so it stays cheap; the 6h cap absorbs abusers invisibly.
- **8h pack = one full workday** of heavy development; bounds any single burst at ~800M tokens.
- **21% off at 160 hours** rewards volume without changing the effective rate current customers already pay ($375/40h = $9.38/hr).
- 90-day expiry prevents hoarding and keeps demand predictable.
- Overage is throttled, not cut — commercial users get predictability, not a cliff.

---

## 5. Website SKU / Copy Notes

- SKU slugs: `gpu-res-6h-addon`, `gpu-com-8h`, `gpu-com-160h-volume`
- Badge the volume deal: **"Buy 160 hrs — save 21%"** ($1,900 → $1,500).
- Copy line for packs: *"One pack = one full day of heavy GPU work."*
- Residential add-on copy: *"Add 6 GPU-hours to your residential plan — only when you need it."*
- Show **remaining hours + expiry** in user dashboard (required for expiry enforcement).
- Display worst-case throughput disclaimer: *"Rates assume heavy agentic coding workloads (~100M tokens/hr). Median usage is far lower."*

---

## 6. Launch Checklist

- [ ] Remove/replace old "infinite use" GPU product pages (301 redirect to new tiers) — ensure copy no longer implies GPU is ever unlimited; only CPU is
- [ ] Update residential package copy: "Unlimited CPU use" (not "unlimited everything")
- [ ] Publish pricing table above
- [ ] Add +6h GPU add-on toggle to residential account/billing flow
- [ ] Implement 8h pack purchase + 160h volume discount (auto-apply at 20 packs)
- [ ] Implement expiry countdown on dashboard
- [ ] Implement idle timeout + concurrency enforcement
- [ ] Set up per-key metering dashboard
- [ ] Configure overage throttle + $12/GPU-hr metered billing
- [ ] Update ToS fair-use section to reference caps in Section 3