"""Policy-as-code for the Kubernetes manifests.

These run in milliseconds without a cluster and encode the rules a reviewer
would otherwise have to remember. A new workload that forgets a probe, runs as
root, or leaves a Service selecting nothing fails CI before it reaches review.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "k8s" / "base"
OVERLAYS = ROOT / "k8s" / "overlays"


def load_all(directory: Path) -> list[dict]:
    docs = []
    for f in sorted(directory.rglob("*.yaml")):
        if f.name == "kustomization.yaml":
            continue
        docs += [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if d]
    return docs


DOCS = load_all(BASE)
WORKLOADS = [d for d in DOCS if d["kind"] in {"Deployment", "StatefulSet"}]
CONTAINERS = [(w["metadata"]["name"], c) for w in WORKLOADS for c in w["spec"]["template"]["spec"]["containers"]]
ids = [f"{w}/{c['name']}" for w, c in CONTAINERS]


def pod_labels() -> list[dict]:
    return [w["spec"]["template"]["metadata"]["labels"] for w in WORKLOADS]


def selects_something(selector: dict) -> bool:
    return any(all(labels.get(k) == v for k, v in selector.items()) for labels in pod_labels())


def test_manifests_found():
    assert {w["metadata"]["name"] for w in WORKLOADS} == {"storefront", "llm-gateway", "pulse"}


# ---------- security ----------


@pytest.mark.parametrize(("workload", "container"), CONTAINERS, ids=ids)
def test_container_is_locked_down(workload, container):
    sc = container.get("securityContext", {})
    assert sc.get("allowPrivilegeEscalation") is False
    assert sc.get("readOnlyRootFilesystem") is True
    assert sc.get("capabilities", {}).get("drop") == ["ALL"]


@pytest.mark.parametrize("workload", WORKLOADS, ids=[w["metadata"]["name"] for w in WORKLOADS])
def test_pod_runs_as_non_root_with_seccomp(workload):
    spec = workload["spec"]["template"]["spec"]
    assert spec["securityContext"]["runAsNonRoot"] is True
    assert spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert spec.get("automountServiceAccountToken") is False  # no API token unless needed


def test_no_secrets_committed():
    assert not [d for d in load_all(ROOT / "k8s") if d["kind"] == "Secret"]


@pytest.mark.parametrize(("workload", "container"), CONTAINERS, ids=ids)
def test_secrets_come_from_secret_refs_not_literals(workload, container):
    for env in container.get("env", []):
        if any(word in env["name"].upper() for word in ("SECRET", "PASSWORD", "API_KEY", "DATABASE_URL")):
            assert "valueFrom" in env, f"{env['name']} must use secretKeyRef"


def test_namespaces_enforce_restricted_pod_security():
    for overlay in OVERLAYS.iterdir():
        ns = yaml.safe_load((overlay / "namespace.yaml").read_text(encoding="utf-8"))
        assert ns["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "restricted"


def test_default_deny_network_policy_exists():
    policies = [d for d in DOCS if d["kind"] == "NetworkPolicy"]
    deny = [p for p in policies if p["spec"]["podSelector"] == {}]
    assert deny and set(deny[0]["spec"]["policyTypes"]) == {"Ingress", "Egress"}


def test_egress_never_reaches_instance_metadata():
    for p in (d for d in DOCS if d["kind"] == "NetworkPolicy"):
        for rule in p["spec"].get("egress", []):
            for peer in rule.get("to", []):
                block = peer.get("ipBlock")
                if block and block["cidr"] == "0.0.0.0/0":
                    assert "169.254.169.254/32" in block.get("except", []), p["metadata"]["name"]


# ---------- reliability ----------


@pytest.mark.parametrize(("workload", "container"), CONTAINERS, ids=ids)
def test_container_has_probes_and_resources(workload, container):
    assert "readinessProbe" in container and "livenessProbe" in container
    assert container["resources"]["requests"]["cpu"]
    assert container["resources"]["requests"]["memory"]
    assert container["resources"]["limits"]["memory"]  # OOM bound; CPU limit deliberately omitted


def test_stateless_deployments_have_hpa_and_pdb():
    deployments = {d["metadata"]["name"] for d in DOCS if d["kind"] == "Deployment"}
    hpas = {d["spec"]["scaleTargetRef"]["name"] for d in DOCS if d["kind"] == "HorizontalPodAutoscaler"}
    pdbs = [d for d in DOCS if d["kind"] == "PodDisruptionBudget"]
    assert deployments <= hpas
    for name in deployments:
        assert any(p["spec"]["selector"]["matchLabels"].get("app.kubernetes.io/name") == name for p in pdbs)


def test_rolling_updates_never_reduce_capacity():
    for d in (d for d in DOCS if d["kind"] == "Deployment"):
        assert d["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0


# ---------- wiring ----------


def test_every_service_selects_a_workload():
    for s in (d for d in DOCS if d["kind"] == "Service"):
        assert selects_something(s["spec"]["selector"]), s["metadata"]["name"]


def test_every_network_policy_targets_a_workload():
    for p in (d for d in DOCS if d["kind"] == "NetworkPolicy"):
        sel = p["spec"]["podSelector"].get("matchLabels", {})
        assert sel == {} or selects_something(sel), p["metadata"]["name"]


def test_ingress_backends_exist_and_overlays_pin_every_image():
    services = {d["metadata"]["name"] for d in DOCS if d["kind"] == "Service"}
    images = {c["image"].split(":")[0] for _, c in CONTAINERS}
    for overlay in OVERLAYS.iterdir():
        ingress = yaml.safe_load((overlay / "ingress.yaml").read_text(encoding="utf-8"))
        for rule in ingress["spec"]["rules"]:
            for path in rule["http"]["paths"]:
                assert path["backend"]["service"]["name"] in services
        kustomization = yaml.safe_load((overlay / "kustomization.yaml").read_text(encoding="utf-8"))
        pinned = {i["name"] for i in kustomization["images"] if i["newTag"] != "latest"}
        assert images <= pinned, f"{overlay.name} must pin every image tag"
