# Runbook: llm-gateway

**Owner:** platform · **SLO:** 99.5% availability (30 days) · **Dashboard:** *LLM Gateway* in Grafana

## Error budget burn

**Means:** many requests are failing with `all_providers_failed`, `upstream_failed` or `stream_interrupted`. The burn rate is in the alert.

1. **Is one provider down?** Check `gateway_breaker_open` on the dashboard and the vendor status pages (status.anthropic.com, status.cloud.google.com).
   - If one target's breaker is open and the fallback is healthy, the gateway is doing its job, and errors should be dropping. Confirm with `gateway:error_ratio:rate5m`.
   - If **every** target in a route is failing, the route needs another fallback. Add one to `gateway.toml` in `k8s/base/llm-gateway/`, open a PR, and let Argo CD sync it. A fallback to a cheaper model is better than an outage.
2. **Is it us?** `kubectl -n apps-prod get pods -l app.kubernetes.io/name=llm-gateway`. Look for crash loops, OOMKilled, or a recent rollout (`kubectl rollout history`).
   - If it started with a deploy, revert the image-tag commit in this repo and Argo CD syncs the previous version back. Rolling back is always the first move. Debugging comes after.
3. **Are egress or credentials broken?** `upstream_rejected` combined with 401/403 points at an expired provider key. Rotate it in the secret store. The pods pick it up on restart.

## Breaker open

A ticket, not a page. Traffic is already on fallbacks, so the job is to confirm the provider recovers. Breakers half-open every 30 s, so a breaker that stays open means every probe is still failing. If it lasts more than an hour, tell the teams on that route that responses come from the fallback model.

## Spend anomaly

One key is spending more than 3× its weekly average. Usually this is a retry loop or a batch job someone forgot about.
1. Find the key in `gateway:cost_usd:rate1h` and contact the owning team.
2. If spend is runaway and the owner can't be reached, **lower that key's `monthly_budget_usd`**. The gateway then returns 402 to that key only, and every other key is unaffected.

## Useful queries

```promql
gateway:error_ratio:rate5m                                   # current error ratio
sum by (target, result) (rate(gateway_upstream_calls_total[5m]))
gateway:latency_seconds:p95_5m
sum by (key) (increase(gateway_cost_usd_total[24h]))         # spend per key, last 24h
```
