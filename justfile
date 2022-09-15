nv_470_driver := "470.57.02"
nv_510_driver := "510.47.03"
registry := "docker.io/alexeldeib"

default:

pushallcuda: (pushcuda cuda_515_driver) (pushcuda cuda_510_driver) (pushcuda cuda_470_driver) 

pushallgrid: (pushgrid grid_510_driver grid_510_url) (pushgrid grid_470_driver grid_470_url)

push: (build)
	docker push {{ registry }}/aks-gpu:{{ nv_470_driver }}
	docker push {{ registry }}/aks-gpu:{{ nv_510_driver }}

build:
	docker build --build-arg DRIVER_VERSION={{ nv_470_driver }} -f Dockerfile  -t {{ registry }}/aks-gpu:{{ nv_470_driver }} .
	docker build --build-arg DRIVER_VERSION={{ nv_510_driver }} -f Dockerfile  -t {{ registry }}/aks-gpu:{{ nv_510_driver }} .
