"""The Kubernetes API, as your kubeconfig reaches it. Objects go in and come out as plain dicts.

Any kind works the same way (Argo's Workflows too), through the API's discovery: kind is named as
(api_version, kind), e.g. ("v1", "ConfigMap") or ("argoproj.io/v1alpha1", "Workflow").
"""
import time
from pathlib import Path
from urllib.parse import urlparse

from kubernetes import client, config
from kubernetes.dynamic import DynamicClient
from kubernetes.dynamic.exceptions import NotFoundError, ResourceNotFoundError

from .. import LisaError
from ..paths import OWNER


class Cluster:
    def __init__(self, kubeconfig: Path, discovery_cache: Path):
        try:
            self.api_client = config.new_client_from_config(config_file=str(kubeconfig))
        except Exception as e:
            raise LisaError(f"cannot use the kubeconfig {kubeconfig}: {e}") from None
        self._cache = discovery_cache
        self._dyn = DynamicClient(self.api_client, cache_file=str(discovery_cache))

    # --- where the API is -------------------------------------------------------------------------
    @property
    def server(self) -> tuple[str, int]:
        u = urlparse(self.api_client.configuration.host)
        return u.hostname or "", u.port or 443

    @property
    def ca_file(self) -> str | None:
        """The API server's CA as a file (the client writes an embedded one to a temporary file)."""
        return self.api_client.configuration.ssl_ca_cert

    # --- objects ----------------------------------------------------------------------------------
    def kind(self, api_version: str, kind: str):
        try:
            return self._dyn.resources.get(api_version=api_version, kind=kind)
        except ResourceNotFoundError:
            self._dyn.resources.invalidate_cache()      # e.g. Argo's kinds, just installed
            try:
                return self._dyn.resources.get(api_version=api_version, kind=kind)
            except ResourceNotFoundError:
                raise LisaError(f"the cluster has no kind {kind} ({api_version})") from None

    def get(self, api_version: str, kind: str, name: str, namespace: str | None = None) -> dict | None:
        try:
            return self._dyn.get(self.kind(api_version, kind), name=name, namespace=namespace).to_dict()
        except NotFoundError:
            return None

    def list(self, api_version: str, kind: str, namespace: str | None = None, *,
             labels: str | None = None, fields: str | None = None) -> list[dict]:
        r = self._dyn.get(self.kind(api_version, kind), namespace=namespace,
                          label_selector=labels, field_selector=fields)
        return r.to_dict().get("items", [])

    def apply(self, obj: dict, namespace: str | None = None) -> dict:
        """Create or update, as 'kubectl apply --server-side' does. namespace: for a namespaced kind
        whose object names none."""
        kind = self.kind(obj["apiVersion"], obj["kind"])
        if kind.namespaced and namespace:
            obj.setdefault("metadata", {}).setdefault("namespace", namespace)
        return self._dyn.server_side_apply(kind, body=obj, field_manager=OWNER,
                                           force_conflicts=True).to_dict()

    def create(self, obj: dict, namespace: str | None = None) -> dict:
        return self._dyn.create(self.kind(obj["apiVersion"], obj["kind"]), body=obj,
                                namespace=namespace).to_dict()

    def merge_patch(self, api_version: str, kind: str, name: str, patch: dict,
                    namespace: str | None = None) -> dict:
        return self._dyn.patch(self.kind(api_version, kind), body=patch, name=name, namespace=namespace,
                               content_type="application/merge-patch+json").to_dict()

    def delete(self, api_version: str, kind: str, name: str, namespace: str | None = None) -> bool:
        """Delete if it exists; True when something was deleted."""
        try:
            self._dyn.delete(self.kind(api_version, kind), name=name, namespace=namespace)
            return True
        except NotFoundError:
            return False

    def delete_all(self, api_version: str, kind: str, namespace: str, labels: str) -> int:
        items = self.list(api_version, kind, namespace, labels=labels)
        for i in items:
            self.delete(api_version, kind, i["metadata"]["name"], namespace)
        return len(items)

    # --- deployments, pods, nodes, certificates ---------------------------------------------------
    def wait_deployment(self, namespace: str, name: str, timeout: int = 300) -> bool:
        """Until every replica of the current version is ready (kubectl rollout status)."""
        end = time.time() + timeout
        while time.time() < end:
            d = self.get("apps/v1", "Deployment", name, namespace) or {}
            s, want = d.get("status", {}), d.get("spec", {}).get("replicas", 1)
            if (s.get("observedGeneration", 0) >= d.get("metadata", {}).get("generation", 1)
                    and s.get("updatedReplicas", 0) == want and s.get("readyReplicas", 0) == want
                    and s.get("replicas", 0) == want):
                return True
            time.sleep(3)
        return False

    def pod_log(self, namespace: str, pod: str, container: str, tail: int | None = None) -> str:
        try:
            return client.CoreV1Api(self.api_client).read_namespaced_pod_log(
                pod, namespace, container=container, tail_lines=tail)
        except Exception as e:      # the API server could not fetch it from the (virtual) kubelet
            return f"(no log: {getattr(e, 'reason', None) or e})\n"

    def node_ready(self, name: str) -> bool:
        node = self.get("v1", "Node", name) or {}
        return any(c.get("type") == "Ready" and c.get("status") == "True"
                   for c in node.get("status", {}).get("conditions", []))

    def approve_csr(self, name: str) -> None:
        csr = self.get("certificates.k8s.io/v1", "CertificateSigningRequest", name)
        csr.setdefault("status", {}).setdefault("conditions", []).append({
            "type": "Approved", "status": "True", "reason": "LisaRunner",
            "message": "the serving certificate of our own virtual kubelet"})
        self._dyn.replace(self.kind("certificates.k8s.io/v1", "CertificateSigningRequest").approval,
                          body=csr, name=name)

    # --- who we are -------------------------------------------------------------------------------
    def whoami(self) -> str:
        r = self.create({"apiVersion": "authentication.k8s.io/v1", "kind": "SelfSubjectReview"})
        return r.get("status", {}).get("userInfo", {}).get("username", "")

    def is_cluster_admin(self) -> bool:
        r = self.create({"apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                         "spec": {"resourceAttributes": {"verb": "*", "resource": "*", "group": "*"}}})
        return bool(r.get("status", {}).get("allowed"))

    def version(self) -> str:
        v = client.VersionApi(self.api_client).get_code()
        return f"Kubernetes {v.git_version} ({v.platform})"
