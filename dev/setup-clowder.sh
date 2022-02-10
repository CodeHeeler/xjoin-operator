#!/bin/bash

INCLUDE_EXTRA_STUFF=$1

function print_start_message() {
  echo -e "\n********************************************************************************"
  echo -e "* $1"
  echo -e "********************************************************************************\n"
}

function wait_for_pod_to_be_running() {
  SELECTOR=$1
  echo -e "waiting for resource to be created: $SELECTOR"
  # shellcheck disable=SC2034
  for i in {1..240}; do
    POD=$(kubectl get pods --selector="$SELECTOR" -o name)
    if [ -z "$POD" ]; then
      sleep 1
    else
        echo -e "resource created: $SELECTOR"
        break
    fi
  done

  echo -e "waiting for resource to be ready: $SELECTOR"
  kubectl wait --for=condition=ContainersReady=True --selector="$SELECTOR" pods -n test --timeout=600s
}

kubectl create ns test

if [ "$INCLUDE_EXTRA_STUFF" = true ]; then
  # OLM
  print_start_message "Installing OLM"
  CURRENT_DIR=$(pwd)
  mkdir /tmp/olm
  cd /tmp/olm || exit 1
  curl -L https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.18.3/install.sh -o install.sh
  chmod +x install.sh
  ./install.sh v0.18.3
  rm -r /tmp/olm
  cd "$CURRENT_DIR" || exit 1
fi

# kube_setup.sh
print_start_message "Running kube-setup.sh"
CURRENT_DIR=$(pwd)
mkdir /tmp/kubesetup
cd /tmp/kubesetup || exit 1

if [ -z "$KUBE_SETUP_PATH" ]; then
  echo "Using default kube_setup from github"
  curl https://raw.githubusercontent.com/RedHatInsights/clowder/master/build/kube_setup.sh -o /tmp/kubesetup/kube_setup.sh && chmod +x /tmp/kubesetup/kube_setup.sh
  sed -i 's/^install_xjoin_operator//g' ./kube_setup.sh
  sed -i 's/^install_cyndi_operator//g' ./kube_setup.sh
  sed -i 's/^install_keda_operator//g' ./kube_setup.sh
  /tmp/kubesetup/kube_setup.sh
fi

rm -r /tmp/kubesetup
cd "$CURRENT_DIR" || exit 1

kubectl set env deployment/strimzi-cluster-operator -n strimzi STRIMZI_IMAGE_PULL_SECRETS=cloudservices-pull-secret

# clowder CRDs
print_start_message "Installing Clowder CRDs"
kubectl apply -f https://github.com/RedHatInsights/clowder/releases/download/v0.28.0/clowder-manifest-v0.28.0.yaml --validate=false

# project and secrets
print_start_message "Setting up pull secrets"
dev/setup.sh --secret --project test

# operator CRDs, configmap, XJoinPipeline
print_start_message "Setting up XJoin operator"
dev/setup.sh --xjoin-operator --dev --project test
kubectl apply -f dev/xjoin-generic.configmap.yaml -n test

# bonfire environment (kafka, connect, etc.)
print_start_message "Setting up bonfire environment"
bonfire process-env -n test -u cloudservices -f ./dev/clowdenv.yaml | oc apply -f - -n test
wait_for_pod_to_be_running strimzi.io/cluster=kafka,strimzi.io/kind=Kafka,strimzi.io/name=kafka-zookeeper
wait_for_pod_to_be_running strimzi.io/cluster=kafka,strimzi.io/kind=Kafka,strimzi.io/name=kafka-kafka
wait_for_pod_to_be_running strimzi.io/cluster=connect

# inventory resources
print_start_message "Setting up host-inventory"
bonfire process host-inventory -n test --no-get-dependencies | oc apply -f - -n test
wait_for_pod_to_be_running app=host-inventory,service=db

# xjoin resources
bonfire process xjoin -n test --no-get-dependencies | oc apply -f - -n test
wait_for_pod_to_be_running elasticsearch.k8s.elastic.co/cluster-name=xjoin-elasticsearch
wait_for_pod_to_be_running pod=xjoin-search-api

dev/forward-ports-clowder.sh test
HBI_USER=$(kubectl -n test get secret/host-inventory-db -o custom-columns=:data.username | base64 -d)
HBI_NAME=$(kubectl -n test get secret/host-inventory-db -o custom-columns=:data.name | base64 -d)
psql -U "$HBI_USER" -h inventory-db -p 5432 -d "$HBI_NAME" -c "CREATE USER insights WITH PASSWORD 'insights' SUPERUSER;"
psql -U "$HBI_USER" -h inventory-db -p 5432 -d "$HBI_NAME" -c "ALTER ROLE insights REPLICATION LOGIN;"
psql -U "$HBI_USER" -h inventory-db -p 5432 -d "$HBI_NAME" -c "CREATE PUBLICATION dbz_publication FOR TABLE hosts;"
psql -U "$HBI_USER" -h inventory-db -p 5432 -d "$HBI_NAME" -c "CREATE DATABASE test WITH TEMPLATE '$HBI_NAME';"

# elasticsearch
print_start_message "Setting up elasticsearch password"
dev/setup.sh --elasticsearch --project test

if [ "$INCLUDE_EXTRA_STUFF" = true ]; then
  # cats resources
  print_start_message "Setting up cats"
  kubectl apply -f dev/demo/cats.db.yaml
  wait_for_pod_to_be_running app=cats,service=db
  dev/forward-ports-clowder.sh test

  # APICurio operator
  print_start_message "Installing Apicurio"
  kubectl create namespace apicurio-registry-operator-namespace
  curl -sSL "https://raw.githubusercontent.com/Apicurio/apicurio-registry-operator/v1.0.0/docs/resources/install.yaml" | sed "s/apicurio-registry-operator-namespace/test/g" | kubectl apply -f - -n test
  wait_for_pod_to_be_running name=apicurio-registry-operator

  # XJoin API Gateway
  print_start_message "Setting up xjoin-api-gateway"
  bonfire process xjoin-api-gateway -n test --no-get-dependencies -p xjoin-api-gateway/SCHEMA_REGISTRY_HOSTNAME=apicurio -p xjoin-api-gateway/SCHEMA_REGISTRY_PORT=1080 | oc apply -f - -n test
  wait_for_pod_to_be_running app=xjoin-api-gateway

  # APICurio resource
  kubectl apply -f dev/apicurio.yaml -n test
  wait_for_pod_to_be_running name=example-apicurioregistry-kafkasql
fi

