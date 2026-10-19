# platform

**Infrastructure and operations for my services: AWS with Terraform (VPC, EKS, RDS Postgres), Kubernetes with Kustomize, GitOps with Argo CD, SLO-based alerting with tested Prometheus rules, a Grafana dashboard, runbooks, and policy-as-code.**

![terraform](https://img.shields.io/badge/Terraform-AWS-7B42BC?logo=terraform&logoColor=white)
![kubernetes](https://img.shields.io/badge/Kubernetes-1.31-326CE5?logo=kubernetes&logoColor=white)
![argo](https://img.shields.io/badge/GitOps-Argo%20CD-EF7B4D?logo=argo&logoColor=white)
![prometheus](https://img.shields.io/badge/SLOs-Prometheus-E6522C?logo=prometheus&logoColor=white)

It runs [storefront](https://github.com/affifariza04/storefront), [llm-gateway](https://github.com/affifariza04/llm-gateway) and [pulse](https://github.com/affifariza04/pulse).

> **Honest scope:** none of this is provisioned. Running EKS, multi-AZ RDS and NAT gateways costs real money. Everything is **validated in CI** instead: `terraform validate`, `kubeconform` against the Kubernetes 1.31 schemas, `promtool` unit tests for alerts, Trivy misconfiguration scanning, and policy tests.

## Architecture

```
                         ┌──────────────── AWS ap-southeast-3 (Jakarta), 3 AZs ────────────────┐
  users ─▶ NLB ─▶ ingress-nginx ─┬─▶ storefront (Deployment, HPA 3-10, PDB) ──▶ RDS Postgres 16  │
          (TLS: cert-manager)    └─▶ pulse (StatefulSet + PVC, WebSockets)       Multi-AZ, private │
                                                                                 subnets, IAM auth │
                    internal ──▶ llm-gateway (Deployment, HPA) ──443──▶ Anthropic / Gemini APIs │
                         │                                                                          │
                         └── EKS: private nodes, IMDSv2-only, KMS-encrypted secrets, IRSA ─────────┘
  git push ─▶ CI builds image ─▶ tag in overlays/staging ─▶ Argo CD syncs ─▶ promote PR ─▶ production
```

## Repository map

| Path | What |
|---|---|
| [`terraform/modules`](terraform/modules) | `network` (VPC, flow logs, isolated DB subnets), `cluster` (EKS), `database` (RDS) |
| [`terraform/envs`](terraform/envs) | `staging` (single NAT, single-AZ DB, disposable) and `production` (NAT per AZ, Multi-AZ, deletion protection) |
| [`k8s/base`](k8s/base) | One directory per service plus a namespace-wide **default-deny** NetworkPolicy |
| [`k8s/overlays`](k8s/overlays) | Per-environment namespace (Pod Security `restricted`), pinned image tags, replica and PDB patches, Ingress |
| [`gitops`](gitops) | Argo CD Applications. Staging prunes automatically. Production never auto-deletes. |
| [`observability`](observability) | SLO recording and alert rules with **unit tests**, plus the Grafana dashboard |
| [`docs/runbooks`](docs/runbooks) | What on-call does when each alert fires |
| [`tests`](tests) | Policy-as-code: 22 checks over every manifest |

## Decisions that matter

**Security by default**
- Every pod is non-root, uses the seccomp `RuntimeDefault` profile, has a read-only root filesystem, drops all capabilities, and doesn't mount a ServiceAccount token. The namespace enforces it through Pod Security Admission `restricted`, so a pod that drifts is **rejected**, not just flagged.
- Network policy is deny-all. Each service then opens exactly the paths it needs: storefront → Postgres:5432, llm-gateway → :443 only, and nothing can reach `169.254.169.254` (cloud instance metadata, the classic SSRF pivot).
- The RDS master password is **managed by AWS Secrets Manager** (`manage_master_user_password`), so it never exists in Terraform state, code, or CI logs. TLS is forced, and IAM auth is enabled.
- The **EKS API is private**. GitOps is a pull model (Argo CD runs inside the cluster), so CI never needs to reach the Kubernetes API, which removes the most common way clusters get attacked. EKS also uses KMS envelope encryption for Secrets, IRSA for pod IAM, and IMDSv2 with hop limit 1 on nodes.
- Trivy scans every push and fails on HIGH/CRITICAL. The one accepted finding (node-level egress, needed for image pulls and LLM APIs) is justified in [`.trivyignore`](.trivyignore) and enforced per pod by NetworkPolicy instead.

**Reliability**
- Rolling updates use `maxUnavailable: 0`. A `preStop` sleep lets the load balancer drain before SIGTERM. Topology spread covers three AZs.
- PDBs keep 2 of 3 replicas through node drains. The production HPA floor is 3, so each AZ has one replica.
- **No CPU limits, only memory limits.** CPU limits cause CFS throttling and tail-latency spikes. Memory limits bound the blast radius of a leak.
- llm-gateway gets a 120 s termination grace period so in-flight LLM streams finish during a rollout.
- pulse is **deliberately one replica** (a StatefulSet with a PVC). Its rooms live in memory, and two replicas would split conversations. The manifest says so, which is better than an HPA that silently breaks it.

**Operations**
- **SLO alerting, not threshold alerting.** llm-gateway has a 99.5% availability SLO with multi-window burn-rate alerts (14.4× over 1h, 6× over 6h, 1× over 3d). Client errors (429/402/401) are excluded from the error ratio, because they're not outages. [`slo-rules.test.yaml`](observability/prometheus/slo-rules.test.yaml) proves that a real outage pages and that healthy traffic full of rate-limited clients doesn't.
- Every page links a [runbook](docs/runbooks/llm-gateway.md), and the first step is always "roll back".
- **GitOps:** the cluster state is a git commit. Promotion to production is a [pull request](.github/workflows/promote.yml) that copies the tag already running in staging, and rollback is a revert.

## Validate locally

```bash
uv run pytest -q                                   # policy tests (no cluster needed)
kubectl kustomize k8s/overlays/production | kubeconform -strict -summary -
promtool test rules observability/prometheus/slo-rules.test.yaml
terraform -chdir=terraform/envs/staging init -backend=false && terraform -chdir=terraform/envs/staging validate
```

## Next

External Secrets Operator (secrets from AWS Secrets Manager into Kubernetes), Argo Rollouts canaries gated on the SLO metrics, KEDA request-rate autoscaling for the gateway, and Karpenter for node provisioning.
