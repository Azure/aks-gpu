default: push

push: (containerize)
	docker push docker.io/alexeldeib/aks-gpu:latest

containerize:
	docker build -f Dockerfile  -t docker.io/alexeldeib/aks-gpu:latest .
