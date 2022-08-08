# Driver container image for AKS VHD

This repo provides steps to build a container image with all components required for 
Kubernetes Nvidia GPU integration. Run it as a privileged container in the host PID namespace.
It will enter the host mount namespace and install the nvidia drivers, container runtime, 
and associated libraries on the host, validating their functionality

## Build
```
docker build -f Dockerfile  -t docker.io/alexeldeib/aks-gpu:latest .
docker push docker.io/alexeldeib/aks-gpu:latest
```

## Run
```bash
mkdir -p /opt/{actions,gpu}
ctr image pull docker.io/alexeldeib/aks-gpu:latest
ctr run --privileged --net-host --with-ns pid:/proc/1/ns/pid --mount type=bind,src=/opt/gpu,dst=/mnt/gpu,options=rbind --mount type=bind,src=/opt/actions,dst=/mnt/actions,options=rbind -t docker.io/alexeldeib/aks-gpu:latest /entrypoint.sh install.sh
```

or Docker (untested...)
```bash
docker run -it --privileged --net=host -v /opt/gpu:/mnt/gpu -v /opt/actions:/mnt/actions --rm docker.io/alexeldeib/aks-gpu:latest install
```

Note the `--with-ns pid:/proc/1/ns/pid` and `--privileged`, as well as the bind mounts, these are key.

## Fabric manager installation

This repo also includes an installation script for Nvidia's fabric manager component.
There is an existing installation script in the redistributed files, but in the latest
versions some of the filepaths changed and it seems broken. This is a workaround until 
an upstream fix lands.

```bash

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
