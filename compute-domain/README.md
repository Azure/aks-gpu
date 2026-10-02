# Managed ComputeDomain (GB200/GB300)

Helm chart for the **AKS-managed NVIDIA ComputeDomain controller** — the cluster-scoped
piece of the Grace-Blackwell cross-node NVLink (MNNVL / IMEX) stack. It is delivered as an
AKS core extension (`microsoft.managedcomputedomain`), analogous to how managed DRANET
(`microsoft.manageddranet`) is delivered.

## What this chart deploys

| Object | Purpose |
|---|---|
| `Deployment/compute-domain-controller` | cluster-scoped controller: reconciles `ComputeDomain` CRs, creates the workload `ResourceClaimTemplate`, and (driverManaged) spawns a per-ComputeDomain `compute-domain-daemon` DaemonSet |
| `ServiceAccount` + `ClusterRole` + `ClusterRoleBinding` | controller identity + RBAC, bound to the SA (blast radius = the controller pod, **not** `system:nodes`) |
| `DeviceClass/compute-domain-default-channel.nvidia.com` | the IMEX channel device workloads claim |
| `DeviceClass/compute-domain-daemon.nvidia.com` | the daemon device (driverManaged) |

## What this chart does NOT deliver

- **`compute-domain-daemon`** — not a static object; the controller creates it as a
  per-ComputeDomain DaemonSet at runtime, from the controller's **own image** (so the image
  must carry both `compute-domain-controller` and `compute-domain-daemon`).
- **`compute-domain-kubelet-plugin`** — runs as a host **systemd** service (delivered via the
  `dra-driver-nvidia-gpu` deb), not by this chart. Its node-identity RBAC (2 read-only
  `resource.nvidia.com` reads bound to `system:nodes`) is delivered separately.
- **`nvidia-imex`** — the host binary, installed by **aks-gpu** at boot; the daemon pod execs
  it via CDI. The host `nvidia-imex.service` stays **off** in driverManaged.

## IMEX mode: driverManaged (only)

This chart hard-defaults to `imex.mode: driverManaged`. `hostManaged` is intentionally not
offered: it would require AKS to own the host IMEX topology (`nodes_config.cfg` = the rack
peer set), which cannot be built at node bootstrap (the peer set is cluster-scoped and
converging) and would just re-implement what the driverManaged DaemonSet does automatically
(via pod DNS names).

## Image

The controller image (`compute-domain-controller` + `compute-domain-daemon`) is onboarded via
dalec/MCR; set `image.repository` / `image.tag` in `values.yaml`.

## Upstream

Chart wraps [`kubernetes-sigs/dra-driver-nvidia-gpu`](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu)
`v0.5.0` (controller + DeviceClasses + RBAC derived from its `deployments/helm` templates).
