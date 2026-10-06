import os
import re
import requests
from ruamel.yaml import YAML
from urllib.parse import urlparse

# Values below are fetched from a remote JSON document and end up in
# driver_config.yml, which CI reads and passes to `docker build`. Treat them as
# untrusted input and reject anything that is not a plain version/URL so that
# shell metacharacters can never reach a workflow step.
DRIVER_VERSION_PATTERN = re.compile(r"\A[0-9]+(\.[0-9]+)+\Z")
DRIVER_URL_PATTERN = re.compile(r"\A[A-Za-z0-9._~:/?#@%+=-]+\Z")
ALLOWED_DRIVER_URL_HOSTS = frozenset({"download.microsoft.com"})


def validate_driver_version(version):
    if not isinstance(version, str) or not DRIVER_VERSION_PATTERN.match(version):
        raise ValueError(f"Unexpected driver version from upstream: {version!r}")
    return version


def validate_driver_url(url):
    if not isinstance(url, str) or not DRIVER_URL_PATTERN.match(url):
        raise ValueError(f"Unexpected driver URL from upstream: {url!r}")

    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"Driver URL must use https: {url!r}")
    if parsed.hostname not in ALLOWED_DRIVER_URL_HOSTS:
        raise ValueError(f"Driver URL host is not allowed: {url!r}")
    return url


def get_grid_driver_data():
    # URL of the JSON file containing driver information
    url = "https://raw.githubusercontent.com/Azure/azhpc-extensions/refs/heads/master/NvidiaGPU/Nvidia-GPU-Linux-Resources.json"
    response = requests.get(url, timeout=30)
    response.raise_for_status()
    return response.json()


def get_latest_grid_driver(data, driver_branch):
    candidates = []
    for section in ("Latest", "Archive"):
        for release in data[section]:
            for category in release["Category"]:
                if category["Name"] != "GRID":
                    continue
                for version_info in category["Versions"]:
                    version = validate_driver_version(version_info["DriverVersion"])
                    if version.split(".")[0] == driver_branch:
                        candidates.append(version_info)

    if not candidates:
        raise ValueError(f"Could not find GRID R{driver_branch} in upstream driver metadata")

    latest = max(
        candidates,
        key=lambda item: tuple(int(part) for part in item["DriverVersion"].split(".")),
    )
    version = latest["DriverVersion"]
    url = validate_driver_url(latest["Drivers"][0]["DirLink"])
    expected_filename = f"NVIDIA-Linux-x86_64-{version}-grid-azure.run"
    if os.path.basename(urlparse(url).path) != expected_filename:
        raise ValueError(f"Driver URL does not match GRID version {version}: {url!r}")
    return version, url


def update_driver_config():
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)

    if not os.path.exists("driver_config.yml"):
        raise FileNotFoundError("driver_config.yml not found in the current directory.")
    
    with open("driver_config.yml", "r") as f:
        config = yaml.load(f)
    
    data = get_grid_driver_data()
    for config_key in ("grid", "grid_v20"):
        current_version = validate_driver_version(config[config_key]["version"])
        latest_version, latest_url = get_latest_grid_driver(
            data, current_version.split(".")[0]
        )
        if tuple(map(int, latest_version.split("."))) < tuple(map(int, current_version.split("."))):
            raise ValueError(
                f"Refusing to downgrade {config_key} from {current_version} to {latest_version}"
            )
        config[config_key]["version"] = latest_version
        config[config_key]["url"] = latest_url
        print(f"{config_key}: {current_version} -> {latest_version}")
    
    # Write back to file
    with open("driver_config.yml", "w") as f:
        yaml.dump(config, f)


if __name__ == "__main__":
    update_driver_config()
