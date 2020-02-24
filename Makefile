all: build push
build:
	git submodule update --init --recursive
	docker build . -t zakkg3/docker-taiga -t zakkg3/docker-taiga:latest -t zakkg3/docker-taiga:20181218-4.0.3
push:
	docker push zakkg3/docker-taiga
	docker push zakkg3/docker-taiga:latest
