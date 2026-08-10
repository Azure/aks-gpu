registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda) (pushcudalts)

pushallgrid: (pushgrid) (pushgridv20)

pushrocm: (buildrocm)
	docker push {{ registry }}/aks-gpu:$(yq e '.rocm.version' driver_config.yml)-rocm

pushcuda: (buildcuda)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda

pushcudalts: (buildcudalts)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda_lts.version' driver_config.yml)-cuda-lts

pushgrid: (buildgrid)
	docker push {{ registry }}/aks-gpu:$(yq e '.grid.version' driver_config.yml)-grid

pushgridv20: (buildgridv20)
	docker push {{ registry }}/aks-gpu:$(yq e '.grid_v20.version' driver_config.yml)-grid-v20

buildgrid:
	docker build --build-arg DRIVER_URL=$(yq e '.grid.url' driver_config.yml) --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION=$(yq e '.grid.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildgridv20:
	docker build --build-arg DRIVER_URL=$(yq e '.grid_v20.url' driver_config.yml) --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION=$(yq e '.grid_v20.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.grid_v20.version' driver_config.yml)-grid-v20 .

buildcuda:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION=$(yq e '.cuda.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda .

buildcudalts:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION=$(yq e '.cuda_lts.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.cuda_lts.version' driver_config.yml)-cuda-lts .

buildrocm:
	docker build --build-arg distro=22.04 --build-arg DRIVER_KIND=rocm --build-arg DRIVER_VERSION=$(yq e '.rocm.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.rocm.version' driver_config.yml)-rocm .
