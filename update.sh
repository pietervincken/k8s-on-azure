#!/bin/bash

set -e pipefail

tempdir=$(mktemp -d)

### Helper
get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases" |                 # Get latest release from GitHub api
  jq --raw-output 'map(select(.tag_name |  test("^v.*"))) | map(select(.prerelease | not)) | map(select(.tag_name | test(".*beta.*")|not)) | map(select(.tag_name | test(".*alpha.*")|not)) | map(select(.tag_name | test(".*rc.*")|not)) | first | .tag_name'  # get the tag from tag_name
}

helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

cd k8s/aad-pod-identity
rm -rf resources/render resources/crds
mkdir -p resources/render resources/crds
helm template aad-pod-identity \
    aad-pod-identity/aad-pod-identity \
    -n aad-pod-identity \
    --set rbac.createUserFacingClusterRoles=true \
    | yq -s '"resources/render/" + .metadata.name + "-" + .kind + ".yml"' -
curl -s https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts/aad-pod-identity/crds/crd.yaml | yq -s '"resources/crds/" + .metadata.name + ".yml"' -
cd resources/render
kustomize create app --recursive --autodetect
cd ../crds
kustomize create app --recursive --autodetect
cd ../../../..
echo "Upgraded aad-pod-identity"

mkdir -p k8s/external-secrets-operator || true
cd k8s/external-secrets-operator
rm -rf resources/render/
mkdir -p resources/render
helm template external-secrets \
   external-secrets/external-secrets \
    -n external-secrets \
    --set installCRDs=true | yq -s '"resources/render/" + .metadata.name + "-" + .kind + ".yml"' -
cd resources/render
kustomize create app --recursive --autodetect
cd ../../../..
echo "Upgraded external-secrets-operator"

mkdir -p k8s/external-dns/ || true
cd k8s/external-dns/
rm -rf resources/render/ || true
mkdir -p resources/render
externalDNSOperatorVersion=$(get_latest_release "kubernetes-sigs/external-dns")
git clone -q --depth=1 https://github.com/kubernetes-sigs/external-dns.git --branch $externalDNSOperatorVersion $tempdir/externaldns 2> /dev/null
rm -rf resources/render
mkdir -p resources/render
cp -R $tempdir/externaldns/kustomize/* resources/render
# Stupid workaround for properly doing this :facepalm:
kustomize edit set image k8s.gcr.io/external-dns/external-dns:$externalDNSOperatorVersion 
cd ../../
echo "Upgraded external-dns to $externalDNSOperatorVersion"

aksVersion=$(az aks get-versions --location "westeurope" -o json | jq '.orchestrators[] | select (.isPreview==null) | .orchestratorVersion' | jq -s 'sort | reverse | first' --raw-output)
sed -i .bak "s|kubernetes_version[[:space:]]*=[[:space:]]*\"[0-9]*\.[0-9]*\.[0-9]\"|kubernetes_version  = \"$aksVersion\"|" terraform/main.tf
rm terraform/main.tf.bak
echo "Upgraded aks to $aksVersion"

# # Cleanup
rm -rf $tempdir