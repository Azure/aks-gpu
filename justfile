registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda) (pushcudalts)

pushallgrid: (pushgrid) (pushgridv20)

pushcuda: (buildcuda)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda

pushcudalts: (buildcudalts)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda_lts.version' driver_config.yml)-cuda-lts

pushgrid: (buildgrid)
	docker push {{ registry }}/aks-gpu:$(yq e '.grid.version' driver_config.yml)-grid

pushgridv20: (buildgridv20)
	docker push {{ registry }}/aks-gpu:$(yq e '.grid_v20.version' driver_config.yml)-grid-v20

amd_tag := `echo "$(yq e '.amd.drivers_version' driver_config.yml)-$(yq e '.amd.kernel_full_version' driver_config.yml)"`

pushamd: (buildamd)
	docker push {{ registry }}/aks-gpu:{{ amd_tag }}-amd

buildamd:
	docker build --platform linux/amd64 \
		--build-arg KERNEL_FULL_VERSION=$(yq e '.amd.kernel_full_version' driver_config.yml) \
		--build-arg DRIVERS_VERSION=$(yq e '.amd.drivers_version' driver_config.yml) \
		--build-arg REPO_URL=$(yq e '.amd.repo_url' driver_config.yml) \
		--build-arg PACKAGE_REPO_URL="$(yq e '.amd.package_repo_url' driver_config.yml)" \
		--build-arg GPG_KEY_URL="$(yq e '.amd.gpg_key_url' driver_config.yml)" \
		-f Dockerfile.amd -t {{ registry }}/aks-gpu:{{ amd_tag }}-amd .

buildgrid:
	docker build --build-arg DRIVER_URL=$(yq e '.grid.url' driver_config.yml) --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION=$(yq e '.grid.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildgridv20:
	docker build --build-arg DRIVER_URL=$(yq e '.grid_v20.url' driver_config.yml) --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION=$(yq e '.grid_v20.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.grid_v20.version' driver_config.yml)-grid-v20 .

buildcuda:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION=$(yq e '.cuda.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda .

buildcudalts:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION=$(yq e '.cuda_lts.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.cuda_lts.version' driver_config.yml)-cuda-lts .
