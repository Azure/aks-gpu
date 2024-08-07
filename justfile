registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda)

pushallgrid: (pushgrid)

pushcuda: (buildcuda)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda

pushgrid: (buildgrid)
	docker push {{ registry }}/aks-gpu:$(yq e '.grid.version' driver_config.yml)-grid

buildgrid:
	docker build --build-arg DRIVER_URL=$(yq e '.grid.url' driver_config.yml) --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION=$(yq e '.grid.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildcuda:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION=$(yq e '.cuda.version' driver_config.yml) -f Dockerfile -t {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda .
