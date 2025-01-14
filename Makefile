.PHONY: test build-kong

export SHELL:=/bin/bash

RESTY_IMAGE_BASE?=ubuntu
RESTY_IMAGE_TAG?=xenial
PACKAGE_TYPE?=deb
PACKAGE_TYPE?=debian
OPENRESTY_BUILD_TOOLS_VERSION?=0.0.6

TEST_ADMIN_PROTOCOL?=http://
TEST_ADMIN_PORT?=8001
TEST_HOST?=localhost
TEST_ADMIN_URI?=$(TEST_ADMIN_PROTOCOL)$(TEST_HOST):$(TEST_ADMIN_PORT)
TEST_PROXY_PROTOCOL?=http://
TEST_PROXY_PORT?=8000
TEST_PROXY_URI?=$(TEST_PROXY_PROTOCOL)$(TEST_HOST):$(TEST_PROXY_PORT)

KONG_SOURCE_LOCATION?="$$PWD/../kong/"
EDITION?=`grep EDITION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
KONG_PACKAGE_NAME?="kong"
KONG_CONFLICTS?="kong-enterprise-edition"
KONG_LICENSE?="ASL 2.0"

PRIVATE_REPOSITORY?=true
KONG_TEST_CONTAINER_TAG?=5000/kong-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)
KONG_TEST_CONTAINER_NAME?=localhost:$(KONG_TEST_CONTAINER_TAG)
KONG_VERSION?=`echo $(KONG_SOURCE_LOCATION)/kong-*.rockspec | sed 's,.*/,,' | cut -d- -f2`
RESTY_VERSION ?= `grep RESTY_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_LUAROCKS_VERSION ?= `grep RESTY_LUAROCKS_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_OPENSSL_VERSION ?= `grep RESTY_OPENSSL_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_PCRE_VERSION ?= `grep RESTY_PCRE_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
KONG_GMP_VERSION ?= `grep KONG_GMP_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
KONG_NETTLE_VERSION ?= `grep KONG_NETTLE_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_CONFIG_OPTIONS ?= "--with-cc-opt='-I/tmp/openssl/include' \
  --with-ld-opt='-L/tmp/openssl -Wl,-rpath,/usr/local/kong/lib' \
  --with-pcre=/tmp/pcre-${RESTY_PCRE_VERSION} \
  --with-pcre-jit \
  --with-http_realip_module \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_v2_module \
  --with-stream_ssl_preread_module \
  --with-stream_realip_module \
  "
LIBYAML_VERSION ?= 0.2.1
LYAML_VERSION ?= 6.2.3

DOCKER_MACHINE_ARM64_NAME?=docker-machine-arm64-${USER}

ifeq ($(RESTY_IMAGE_BASE),alpine)
	OPENSSL_EXTRA_OPTIONSs=" -no-async"
endif

BUILDX?=false
ifeq ($(RESTY_IMAGE_BASE),src)
	BUILDX?=false
else ifeq ($(PACKAGE_TYPE),rpm)
	BUILDX?=false
else ifeq ($(RESTY_IMAGE_TAG),jessie)
	BUILDX?=false
endif

BUILDX_INFO := $(shell docker buildx 2>&1 >/dev/null; echo $?)
ifneq ($(BUILDX_INFO),)
	BUILDX=false
endif

ifeq ($(BUILDX),false)
	DOCKER_COMMAND?=docker build
	DOCKER_COMMAND_OUTPUT?=$(DOCKER_COMMAND) -f Dockerfile.kong --build-arg BUILDPLATFORM=x/amd64
else
	DOCKER_COMMAND?=docker buildx build --push --platform="linux/amd64"
	DOCKER_COMMAND_OUTPUT?=docker buildx build --output output --platform="linux/amd64,linux/arm64" -f Dockerfile.kong
endif

# Cache gets automatically busted every week. Set this to unique value to skip the cache
CACHE_BUSTER?=`date +%V`
DOCKER_BASE_SUFFIX=$$(md5sum Dockerfile.${PACKAGE_TYPE} | cut -d' ' -f 1)${CACHE_BUSTER}
OPENRESTY_DOCKER_SHA=$$(md5sum Dockerfile.openresty | cut -d' ' -f 1)
REQUIREMENTS_SHA=$$(md5sum $(KONG_SOURCE_LOCATION)/.requirements | cut -d' ' -f 1)
BUILD_TOOLS_SHA=$$(cd openresty-build-tools/ && git rev-parse --short HEAD)
DOCKER_OPENRESTY_SUFFIX=${OPENRESTY_DOCKER_SHA}${REQUIREMENTS_SHA}${BUILD_TOOLS_SHA}${CACHE_BUSTER}

setup-ci:
	.ci/setup_ci.sh
	.ci/setup_kind.sh

setup-build:
ifeq ($(BUILDX),true)
	docker buildx create --name multibuilder
	docker-machine create --driver amazonec2 --amazonec2-instance-type a1.medium --amazonec2-region us-east-1 --amazonec2-ami ami-0c46f9f09e3a8c2b5 --amazonec2-monitoring --amazonec2-tags created-by,${USER} ${DOCKER_MACHINE_ARM64_NAME}
	docker context create ${DOCKER_MACHINE_ARM64_NAME} --docker \
	host=tcp://`docker-machine config ${DOCKER_MACHINE_ARM64_NAME} | grep tcp | awk -F "//" '{print $$2}'`,\
	ca=`docker-machine config ${DOCKER_MACHINE_ARM64_NAME} | grep tlscacert | awk -F "=" '{print $$2}' | tr -d "\""`,\
	cert=`docker-machine config ${DOCKER_MACHINE_ARM64_NAME} | grep tlscert | awk -F "=" '{print $$2}' | tr -d "\""`,\
	key=`docker-machine config ${DOCKER_MACHINE_ARM64_NAME} | grep tlskey | awk -F "=" '{print $$2}' | tr -d "\""`
	docker buildx create --name multibuilder --append ${DOCKER_MACHINE_ARM64_NAME}
	docker buildx inspect multibuilder --bootstrap
	docker buildx use multibuilder
endif

cleanup_build:
ifeq ($(BUILDX),true)
	-docker buildx use default
	-docker buildx rm multibuilder
	-docker context rm ${DOCKER_MACHINE_ARM64_NAME}
	-docker-machine rm --force ${DOCKER_MACHINE_ARM64_NAME}
endif

build-base:
ifeq ($(RESTY_IMAGE_BASE),rhel)
	docker pull registry.access.redhat.com/rhel${RESTY_IMAGE_TAG}
	docker tag registry.access.redhat.com/rhel${RESTY_IMAGE_TAG} rhel:${RESTY_IMAGE_TAG}
	PACKAGE_TYPE=rpm
	@$(DOCKER_COMMAND) -f Dockerfile.$(PACKAGE_TYPE) \
	--build-arg RHEL=true \
	--build-arg RESTY_IMAGE_TAG="$(RESTY_IMAGE_TAG)" \
	--build-arg RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	--build-arg REDHAT_USERNAME=$(REDHAT_USERNAME) \
	--build-arg REDHAT_PASSWORD=$(REDHAT_PASSWORD) \
	-t kong/kong-build-tools:$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_BASE_SUFFIX) .
else
	docker pull kong/kong-build-tools:$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_BASE_SUFFIX) || \
	$(DOCKER_COMMAND) -f Dockerfile.$(PACKAGE_TYPE) \
	--build-arg RESTY_IMAGE_TAG="$(RESTY_IMAGE_TAG)" \
	--build-arg RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	-t kong/kong-build-tools:$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_BASE_SUFFIX) .
endif

build-openresty: build-base
	-rm -rf openresty-build-tools
	git clone https://github.com/Kong/openresty-build-tools.git
	cd openresty-build-tools; \
	git fetch; \
	git reset --hard $(OPENRESTY_BUILD_TOOLS_VERSION)
	docker pull kong/kong-build-tools:openresty-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_OPENRESTY_SUFFIX) || \
	$(DOCKER_COMMAND) -f Dockerfile.openresty \
	--build-arg RESTY_VERSION=$(RESTY_VERSION) \
	--build-arg RESTY_LUAROCKS_VERSION=$(RESTY_LUAROCKS_VERSION) \
	--build-arg RESTY_OPENSSL_VERSION=$(RESTY_OPENSSL_VERSION) \
	--build-arg RESTY_PCRE_VERSION=$(RESTY_PCRE_VERSION) \
	--build-arg RESTY_IMAGE_TAG="$(RESTY_IMAGE_TAG)" \
	--build-arg RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	--build-arg DOCKER_BASE_SUFFIX=$(DOCKER_BASE_SUFFIX) \
	--build-arg OPENSSL_EXTRA_OPTIONS=$(OPENSSL_EXTRA_OPTIONS) \
	--build-arg LIBYAML_VERSION=$(LIBYAML_VERSION) \
	--build-arg RESTY_CONFIG_OPTIONS=$(RESTY_CONFIG_OPTIONS) \
	--build-arg EDITION=$(EDITION) \
	--build-arg KONG_GMP_VERSION=$(KONG_GMP_VERSION) \
	--build-arg KONG_NETTLE_VERSION=$(KONG_NETTLE_VERSION) \
	-t kong/kong-build-tools:openresty-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_OPENRESTY_SUFFIX) .

package-kong: build-kong

build-kong: build-openresty
ifneq ($(RESTY_IMAGE_BASE),src)
	-rm -rf kong
	-cp -R $(KONG_SOURCE_LOCATION) kong
	$(DOCKER_COMMAND_OUTPUT) \
	--build-arg RESTY_VERSION=$(RESTY_VERSION) \
	--build-arg RESTY_LUAROCKS_VERSION=$(RESTY_LUAROCKS_VERSION) \
	--build-arg RESTY_OPENSSL_VERSION=$(RESTY_OPENSSL_VERSION) \
	--build-arg RESTY_PCRE_VERSION=$(RESTY_PCRE_VERSION) \
	--build-arg RESTY_IMAGE_TAG="$(RESTY_IMAGE_TAG)" \
	--build-arg RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	--build-arg DOCKER_OPENRESTY_SUFFIX=$(DOCKER_OPENRESTY_SUFFIX) \
	--build-arg OPENSSL_EXTRA_OPTIONS=$(OPENSSL_EXTRA_OPTIONS) \
	--build-arg LIBYAML_VERSION=$(LIBYAML_VERSION) \
	--build-arg RESTY_CONFIG_OPTIONS=$(RESTY_CONFIG_OPTIONS) \
	--build-arg EDITION=$(EDITION) \
	--build-arg KONG_GMP_VERSION=$(KONG_GMP_VERSION) \
	--build-arg KONG_NETTLE_VERSION=$(KONG_NETTLE_VERSION) \
	--build-arg KONG_VERSION=$(KONG_VERSION) \
	--build-arg KONG_PACKAGE_NAME=$(KONG_PACKAGE_NAME) \
	--build-arg KONG_CONFLICTS=$(KONG_CONFLICTS) \
	-t kong/kong-build-tools:kong-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(KONG_VERSION) .
	-cp output/linux*/output/* output/
	-cp output/output/* output/
endif
ifeq ($(BUILDX),false)
	docker run -d --rm --name output kong/kong-build-tools:kong-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(KONG_VERSION) tail -f /dev/null
	docker cp output:/output/ output
	docker stop output
	mv output/output/*.$(PACKAGE_TYPE)* output/
endif
	rm -rf output/*/

release-kong:
	ARCHITECTURE=amd64 \
	RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	RESTY_IMAGE_TAG=$(RESTY_IMAGE_TAG) \
	KONG_PACKAGE_NAME=$(KONG_PACKAGE_NAME) \
	KONG_VERSION=$(KONG_VERSION) \
	BINTRAY_USR=$(BINTRAY_USR) \
	BINTRAY_KEY=$(BINTRAY_KEY) \
	PRIVATE_REPOSITORY=$(PRIVATE_REPOSITORY) \
	./release-kong.sh
ifneq ($(BUILDX),false)
	ARCHITECTURE=arm64 \
	RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	RESTY_IMAGE_TAG=$(RESTY_IMAGE_TAG) \
	KONG_PACKAGE_NAME=$(KONG_PACKAGE_NAME) \
	KONG_VERSION=$(KONG_VERSION) \
	BINTRAY_USR=$(BINTRAY_USR) \
	BINTRAY_KEY=$(BINTRAY_KEY) \
	PRIVATE_REPOSITORY=$(PRIVATE_REPOSITORY) \
	./release-kong.sh
endif

test: build-test-container
	KONG_VERSION=$(KONG_VERSION) \
	RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	RESTY_IMAGE_TAG=$(RESTY_IMAGE_TAG) \
	KONG_PACKAGE_NAME=$(KONG_PACKAGE_NAME) \
	KONG_TEST_CONTAINER_TAG=$(KONG_TEST_CONTAINER_TAG) \
	KONG_TEST_CONTAINER_NAME=$(KONG_TEST_CONTAINER_NAME) \
	./test/run_tests.sh

run_tests:
	cd test && docker build -t kong/kong-build-tools:test-runner -f Dockerfile.test_runner .
	docker run -it --network host -e RESTY_VERSION=$(RESTY_VERSION) -e KONG_VERSION=$(KONG_VERSION) -e ADMIN_URI=$(TEST_ADMIN_URI) -e PROXY_URI=$(TEST_PROXY_URI) kong/kong-build-tools:test-runner /bin/bash -c "py.test -p no:logging -p no:warnings test_*.tavern.yaml"

develop-tests:
	docker run -it --network host --rm -e RESTY_VERSION=$(RESTY_VERSION) -e KONG_VERSION=$(KONG_VERSION) \
	-e ADMIN_URI="https://`kubectl get nodes --namespace default -o jsonpath='{.items[0].status.addresses[0].address}'`:`kubectl get svc --namespace default kong-kong-admin -o jsonpath='{.spec.ports[0].nodePort}'`" \
	-e PROXY_URI="http://`kubectl get nodes --namespace default -o jsonpath='{.items[0].status.addresses[0].address}'`:`kubectl get svc --namespace default kong-kong-proxy -o jsonpath='{.spec.ports[0].nodePort}'`" \
	-v $$PWD/test:/app \
	kong/kong-build-tools:test_runner /bin/bash

build-test-container:
	RESTY_IMAGE_BASE=$(RESTY_IMAGE_BASE) \
	RESTY_IMAGE_TAG=$(RESTY_IMAGE_TAG) \
	KONG_VERSION=$(KONG_VERSION) \
	KONG_PACKAGE_NAME=$(KONG_PACKAGE_NAME) \
	KONG_TEST_CONTAINER_NAME=$(KONG_TEST_CONTAINER_NAME) \
	test/build_container.sh

development:
ifeq ($(RESTY_IMAGE_TAG),xenial)
	$(MAKE) build-openresty
	docker pull kong/kong-build-tools:openresty-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_OPENRESTY_SUFFIX)
	docker tag kong/kong-build-tools:openresty-$(RESTY_IMAGE_BASE)-$(RESTY_IMAGE_TAG)-$(DOCKER_OPENRESTY_SUFFIX) kong/kong-build-tools:openresty-development
	docker build \
	--build-arg KONG_UID=$$(id -u) \
	--build-arg USER=$$USER \
	--build-arg RUNAS_USER=$$USER \
	-f Dockerfile.development \
	-t kong/kong-build-tools:development .
	- docker-compose stop
	- docker-compose rm -f
	USER=$$(id -u) docker-compose up -d && \
	docker-compose exec kong make dev && \
	docker-compose exec kong ln -s /usr/local/openresty/bin/resty /usr/local/bin/resty && \
	docker-compose exec kong /bin/bash
endif

setup-tests: cleanup-tests
	./.ci/setup_kind.sh

cleanup-tests:
	-kind delete cluster

cleanup: cleanup-tests cleanup-build
	-rm -rf kong
	-rm -rf openresty-build-tools
