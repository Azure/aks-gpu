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


def get_latest_grid_driver():
    # URL of the JSON file containing driver information
    url = "https://raw.githubusercontent.com/Azure/azhpc-extensions/refs/heads/master/NvidiaGPU/Nvidia-GPU-Linux-Resources.json"
    response = requests.get(url)
    response.raise_for_status()  
    data = response.json()
    
    # Extract the latest GRID driver information
    grid_versions = data['Latest']['Category']
    grid_info = next((item for item in grid_versions if item["Name"] == "GRID"), None)
    
    if grid_info:
        latest_version_info = grid_info['Versions'][0]
        latest_version = validate_driver_version(latest_version_info['DriverVersion'])
        latest_url = validate_driver_url(latest_version_info['Driver'][0]['DirLink'])
        return latest_version, latest_url
    
    raise Exception("Could not find latest GRID driver version")

# Add this at the end of your update_driver_config function
def update_driver_config():
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)

    if not os.path.exists("driver_config.yml"):
        raise FileNotFoundError("driver_config.yml not found in the current directory.")
    
    with open("driver_config.yml", "r") as f:
        config = yaml.load(f)
    
    # Get latest version and URL
    latest_version, latest_url = get_latest_grid_driver()
    
    # Update the grid section while preserving order
    config['grid']['version'] = latest_version
    config['grid']['url'] = latest_url
    
    # Write back to file
    with open("driver_config.yml", "w") as f:
        yaml.dump(config, f)


if __name__ == "__main__":
    update_driver_config()
