# GPU driver packages for AKS VHD

This repo builds self-contained tar.gz packages with all components required for
Kubernetes NVIDIA GPU integration on Ubuntu hosts. Copy a package to the target VM,
extract it, run the bundled `compile_package.sh` during image build if you want
a kernel-specific precompiled NVIDIA installer, and run `install_package.sh`
later on the host to install the NVIDIA drivers, container runtime tooling, and
associated libraries.

## Build

### CUDA amd64
```
bash ./build_package.sh \
  --driver-kind cuda \
  --driver-version "$(yq e '.cuda.version' driver_config.yml)" \
  --target-arch amd64 \
  --distro 24.04
```

### CUDA arm64
```bash
bash ./build_package.sh \
  --driver-kind cuda \
  --driver-version "$(yq e '.cuda.version' driver_config.yml)" \
  --target-arch arm64 \
  --distro 24.04
```

### GRID amd64
```bash
bash ./build_package.sh \
  --driver-kind grid \
  --driver-version "$(yq e '.grid.version' driver_config.yml)" \
  --driver-url "$(yq e '.grid.url' driver_config.yml)" \
  --target-arch amd64 \
  --distro 24.04
```

Artifacts are written to `./dist`.

Pushes to `main` also publish the generated tar.gz files to a GitHub Release named
`gpu-packages-<commit-sha>`, which makes the packages easy to download from downstream
automation outside the original workflow run.

## Run

### Compile during VHD build
```bash
tar -C /opt -xzf dist/aks-gpu-cuda-<version>-ubuntu-24.04-amd64.tar.gz
cd /opt/aks-gpu-cuda-<version>-ubuntu-24.04-amd64
sudo bash ./compile_package.sh
```

`compile_package.sh` generates a kernel-specific extracted installer tree at
`nvidia-custom/`, writes matching metadata to `nvidia-custom.metadata`, and
prunes the package root down to the runtime-only payload so the image does not
keep the large build-time sources around.

### Install at runtime
```bash
cd /opt/aks-gpu-cuda-<version>-ubuntu-24.04-amd64
sudo bash ./install_package.sh
```

If `nvidia-custom/` exists and matches the current kernel and package metadata,
`install_package.sh` runs `nvidia-installer` directly from that extracted
precompiled tree and skips both runtime self-extraction and runtime driver
compilation. Older package layouts with `nvidia-custom.run` still work as a
fallback. Otherwise it falls back to the original compile-and-install path when
the extracted NVIDIA sources are still present.

For fast-path experiments, `install_package.sh` also supports
`SKIP_LDCONFIG=1` to skip the linker cache refresh after installation; the
script manually `insmod`s the installed NVIDIA modules before validating with
`nvidia-smi`.

The installer removes the extracted payload directory when it completes successfully,
so extract packages into a disposable working directory such as `/tmp`.

## Legacy container compatibility

The old privileged container flow still works during migration.

```bash
docker build \
  --build-arg DRIVER_KIND=cuda \
  --build-arg DRIVER_VERSION="$(yq e '.cuda.version' driver_config.yml)" \
  -f Dockerfile \
  -t aks-gpu:legacy-cuda .

docker run -it --privileged --net=host --pid=host \
  -v /opt/gpu:/mnt/gpu \
  -v /opt/actions:/mnt/actions \
  --rm aks-gpu:legacy-cuda install
```

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
