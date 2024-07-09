grid_470_url    := "https://download.microsoft.com/download/a/3/c/a3c078a0-e182-4b61-ac9b-ac011dc6ccf4/NVIDIA-Linux-x86_64-470.82.01-grid-azure.run"
grid_510_url    := "https://download.microsoft.com/download/6/2/5/625e22a0-34ea-4d03-8738-a639acebc15e/NVIDIA-Linux-x86_64-510.73.08-grid-azure.run"
grid_535_url    := "https://download.microsoft.com/download/8/d/a/8da4fb8e-3a9b-4e6a-bc9a-72ff64d7a13c/NVIDIA-Linux-x86_64-535.161.08-grid-azure.run"

grid_535_driver := "535.161.08"
grid_510_driver := "510.73.08" 
grid_470_driver := "470.82.01" 

cuda_535_driver := "535.161.08"
cuda_550_driver := "550.90.07"
registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda cuda_550_driver) (pushcuda cuda_535_driver)

pushallgrid: (pushgrid grid_510_driver grid_510_url grid_535_driver) #(pushgrid grid_470_driver grid_470_url)

pushcuda VERSION: (buildcuda VERSION)
	docker push {{ registry }}/aks-gpu:{{VERSION}}-cuda

pushgrid VERSION URL: (buildgrid VERSION URL)
	docker push {{ registry }}/aks-gpu:{{VERSION}}-grid

buildgrid VERSION URL:
	docker build --build-arg DRIVER_URL={{URL}} --build-arg DRIVER_KIND=grid --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-grid .

buildcuda VERSION:
	docker build --build-arg DRIVER_KIND=cuda --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-cuda .
