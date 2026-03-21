.PHONY: build deploy clean

build:
	./build.sh

deploy: build
	./deploy.sh

clean:
	rm -f output/whoah-testimage.raw
