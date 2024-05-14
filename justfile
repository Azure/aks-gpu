grid_470_url    := "https://download.microsoft.com/download/a/3/c/a3c078a0-e182-4b61-ac9b-ac011dc6ccf4/NVIDIA-Linux-x86_64-470.82.01-grid-azure.run"
grid_510_url    := "https://download.microsoft.com/download/6/2/5/625e22a0-34ea-4d03-8738-a639acebc15e/NVIDIA-Linux-x86_64-510.73.08-grid-azure.run"
grid_535_url    := "https://download.microsoft.com/download/1/4/4/14450d0e-a3f2-4b0a-9bb4-a8e729e986c4/NVIDIA-Linux-x86_64-535.154.05-grid-azure.run"

grid_535_driver := "535.54.03"
grid_510_driver := "510.73.08" 
grid_470_driver := "470.82.01" 

cuda_510_driver := "510.47.03"
cuda_470_driver := "470.82.01"
cuda_515_driver := "515.65.01"
cuda_535_driver := "535.161.08"
registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda cuda_535_driver) (pushcuda cuda_515_driver) (pushcuda cuda_510_driver) (pushcuda cuda_470_driver) 

pushallgrid: (pushgrid grid_510_driver grid_510_url grid_535_driver) #(pushgrid grid_470_driver grid_470_url)

pushcuda VERSION: (buildcuda VERSION)
	docker push {{ registry }}/aks-gpu:{{VERSION}}-cuda

pushgrid VERSION URL: (buildgrid VERSION URL)
	docker push {{ registry }}/aks-gpu:{{VERSION}}-grid

buildgrid VERSION URL:
	docker build --build-arg DRIVER_URL={{URL}} --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildcuda VERSION:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-cuda .
