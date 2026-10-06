# Driver container image for AKS VHD

This repo provides steps to build a container image with all components required for 
Kubernetes Nvidia GPU integration. Run it as a privileged container in the host PID namespace.
It will enter the host mount namespace and install the nvidia drivers, container runtime, 
and associated libraries on the host, validating their functionality

## GRID driver branches

The GRID images intentionally track different branches from the
[Azure Linux GRID compatibility matrix](https://learn.microsoft.com/azure/virtual-machines/linux/n-series-driver-setup#supported-grid-drivers):

| Configuration | Image | Driver | Azure compatibility |
| --- | --- | --- | --- |
| `grid` | `aks-gpu-grid` | vGPU 19.6 LTS / `580.178.04` | NVadsA10_v5 |
| `grid_v20` | `aks-gpu-grid-v20` | vGPU 20.2 / `595.91.07` | NCv6 RTX PRO 6000 BSE, NCasT4_v3, NVadsA10_v5 |

AgentBaker selects the standard GRID image for its A10 GRID SKUs and the v20 image
for NCv6 RTX PRO 6000 BSE. CUDA driver selection is separate and is unchanged;
the presence of a GRID option for a SKU does not require switching its CUDA
workloads to GRID. The updater checks both upstream `Latest` and `Archive`
releases, but only updates each image within its configured driver branch.

Changing this producer does not update AKS nodes by itself. After the R580 image
is published, AgentBaker must pin its actual MCR tag and constrain Renovate for
`aks/aks-gpu-grid` to R580; existing R595 tags in that repository must not be
selected for the A10 LTS path.

Keeping the R580 option avoids forcing older applications onto R595. For example,
[Isaac Sim 5.1 pins Kit SDK 107.3.3](https://github.com/isaac-sim/IsaacSim/blob/v5.1.0/deps/kit-sdk.packman.xml),
and [upstream reports that this Kit version does not support 59x drivers](https://github.com/isaac-sim/IsaacSim/issues/794#issuecomment-5606456050).
This is not a guarantee for every application: the separate MIG/vGPU identifier
bug in that issue requires a newer Kit version, even with a supported driver.
The exact application workload still needs validation on its target SKU.

## Build
```
docker build -f Dockerfile  --build-arg DRIVER_VERSION=??? -t docker.io/alexeldeib/aks-gpu:latest .
docker push docker.io/alexeldeib/aks-gpu:latest
``` 

#### For DRIVER_VERSION, following versions are known to work :
- 470.82.01
- 510.47.03
- 515.65.01

## Run
```bash
mkdir -p /opt/{actions,gpu}
ctr image pull docker.io/alexeldeib/aks-gpu:latest
ctr run --privileged --net-host --with-ns pid:/proc/1/ns/pid --mount type=bind,src=/opt/gpu,dst=/mnt/gpu,options=rbind --mount type=bind,src=/opt/actions,dst=/mnt/actions,options=rbind -t docker.io/alexeldeib/aks-gpu:latest gpuinstall /entrypoint.sh install
```

or Docker (untested...)
```bash
docker run -it --privileged --net=host --pid=host -v /opt/gpu:/mnt/gpu -v /opt/actions:/mnt/actions --rm docker.io/alexeldeib/aks-gpu:latest install
```

Note the `--with-ns pid:/proc/1/ns/pid` and `--privileged`, as well as the bind mounts, these are key.

## Fabric manager installation

This repo also includes an installation script for Nvidia's fabric manager component.
There is an existing installation script in the redistributed files, but in the latest
versions some of the filepaths changed and it seems broken. This is a workaround until 
an upstream fix lands. See [fabricmanager.md](./fabricmanager.md) for details.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
