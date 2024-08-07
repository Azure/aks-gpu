grid_535_url    := "https://download.microsoft.com/download/8/d/a/8da4fb8e-3a9b-4e6a-bc9a-72ff64d7a13c/NVIDIA-Linux-x86_64-535.161.08-grid-azure.run"

grid_535_driver := "535.161.08"

cuda_550_driver := "550.90.07"
registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda)

pushallgrid: (pushgrid grid_535_driver)

pushcuda: (buildcuda)
	docker push {{ registry }}/aks-gpu:$(yq e '.cuda.version' driver_config.yml)-cuda

pushgrid VERSION URL: (buildgrid VERSION URL)
	docker push {{ registry }}/aks-gpu:{{VERSION}}-grid

buildgrid VERSION URL:
	docker build --build-arg DRIVER_URL={{URL}} --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildcuda VERSION:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-cuda .
