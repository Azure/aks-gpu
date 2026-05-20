import os
import requests
from ruamel.yaml import YAML

# Source of truth for Azure-mirrored NVIDIA GRID drivers. The HPC team
# publishes the canonical driver manifest at this path; resources.json
# contains all currently supported vGPU major versions (we previously read
# Nvidia-GPU-Linux-Resources.json, but that file is no longer updated past
# vGPU 17.55).
RESOURCES_JSON_URL = (
    "https://raw.githubusercontent.com/Azure/azhpc-extensions/"
    "refs/heads/master/NvidiaGPU/resources.json"
)

# Active vGPU major version. Bump this when migrating to the next major
# (e.g. "18" -> "19") and the auto-updater will start tracking the latest
# minor of that major. The auto-updater intentionally does NOT cross major
# versions on its own, since major version bumps require validation.
TARGET_VGPU_MAJOR = "18"


def _vgpu_sort_key(vgpu_version):
    """Convert "18.6" / "18.10" into a tuple for ordering: (18, 6) / (18, 10)."""
    return tuple(int(p) if p.isdigit() else 0 for p in vgpu_version.split("."))


def get_latest_grid_driver():
    """Return (driver_version, download_url) for the latest vGPU TARGET_VGPU_MAJOR.x
    Linux GRID driver.

    Walks OS.Linux.Version[*].Driver[*] in resources.json, collects all entries
    whose vGPUVersion has major == TARGET_VGPU_MAJOR, and picks the one with the
    highest minor. Falls back from DirLink to FwLink so we still get a usable URL
    when the manifest puts the download in FwLink.
    """
    response = requests.get(RESOURCES_JSON_URL, timeout=30)
    response.raise_for_status()
    data = response.json()

    linux_block = next(
        (o for o in data.get("OS", []) if o.get("Name") == "Linux"), None
    )
    if linux_block is None:
        raise RuntimeError("No 'Linux' OS block in NvidiaGPU/resources.json")

    prefix = f"{TARGET_VGPU_MAJOR}."
    candidates = {}
    for distro in linux_block.get("Version", []):
        for drv_block in distro.get("Driver", []):
            if drv_block.get("Type") != "GRID":
                continue
            for v in drv_block.get("Version", []):
                vgpu = str(v.get("vGPUVersion", "")).strip()
                if not vgpu.startswith(prefix):
                    continue
                driver_num = v.get("Num")
                url = v.get("DirLink") or v.get("FwLink")
                if not driver_num or not url:
                    continue
                # Same driver may appear in multiple distro blocks; first wins.
                candidates.setdefault(driver_num, {"vgpu": vgpu, "url": url})

    if not candidates:
        raise RuntimeError(
            f"No vGPU {TARGET_VGPU_MAJOR}.x Linux GRID driver entries found "
            f"in {RESOURCES_JSON_URL}"
        )

    best_num = max(
        candidates,
        key=lambda n: _vgpu_sort_key(candidates[n]["vgpu"]),
    )
    return best_num, candidates[best_num]["url"]


def update_driver_config():
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)

    if not os.path.exists("driver_config.yml"):
        raise FileNotFoundError("driver_config.yml not found in the current directory.")

    with open("driver_config.yml", "r") as f:
        config = yaml.load(f)

    latest_version, latest_url = get_latest_grid_driver()

    config['grid']['version'] = latest_version
    config['grid']['url'] = latest_url

    with open("driver_config.yml", "w") as f:
        yaml.dump(config, f)


if __name__ == "__main__":
    update_driver_config()
