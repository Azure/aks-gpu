nv_470_driver := "470.82.01"
nv_510_driver := "510.73.08"
registry := "docker.io/alexeldeib"

default: (build "510.73.08" "compute") (build "510.73.08" "grid")

push VERSION KIND: (build VERSION KIND)
	# docker push {{ registry }}/aks-gpu:{{ nv_470_driver }}
	docker push {{ registry }}/aks-gpu:{{VERSION}}-{{KIND}}

# build:
# 	# docker build --build-arg DRIVER_VERSION={{ nv_470_driver }} -f Dockerfile  -t {{ registry }}/aks-gpu:{{ nv_470_driver }} .
# 	docker build --build-arg DRIVER_VERSION={{ nv_510_driver }} -f Dockerfile  -t {{ registry }}/aks-gpu:{{ nv_510_driver }} .

build VERSION KIND:
	docker build --build-arg DRIVER_KIND={{KIND}} --build-arg DRIVER_VERSION={{VERSION}} -f Dockerfile -t {{ registry }}/aks-gpu:{{VERSION}}-{{KIND}} .
