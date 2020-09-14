export PROJECT_ID=kenthua-test-service-01
export SERVICE_ACCOUNT=project-service-account@${PROJECT_ID}.iam.gserviceaccount.com
export CLUSTER1=istio-west
export CLUSTER1_LOCATION=us-west1
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

gcloud beta container clusters create ${CLUSTER1} \
  --project ${PROJECT_ID} \
  --service-account ${SERVICE_ACCOUNT} \
  --machine-type e2-standard-4 \
  --num-nodes 2 \
  --release-channel regular \
  --region ${CLUSTER1_LOCATION} \
  --enable-ip-alias \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --enable-intra-node-visibility \
  --async

export CLUSTER_NAME=${CLUSTER1}
export CLUSTER_LOCATION=${CLUSTER1_LOCATION}
export WORKLOAD_POOL=${PROJECT_ID}.svc.id.goog
export MESH_ID="proj-${PROJECT_NUMBER}"
gcloud config set compute/region ${CLUSTER_LOCATION}
gcloud container clusters update ${CLUSTER_NAME} \
  --project=${PROJECT_ID} \
  --update-labels=mesh_id=${MESH_ID}
gcloud container clusters update ${CLUSTER_NAME} \
  --project=${PROJECT_ID} \
  --enable-stackdriver-kubernetes

gcloud container clusters get-credentials istio-west
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole=cluster-admin \
  --user="$(gcloud config get-value core/account)"

kpt pkg get \
  https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm@release-1.6-asm asm
kpt cfg set asm gcloud.core.project ${PROJECT_ID}
kpt cfg set asm gcloud.project.environProjectNumber $PROJECT_NUMBER
kpt cfg set asm gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set asm gcloud.compute.location ${CLUSTER_LOCATION}
kpt cfg set asm anthos.servicemesh.profile asm-gcp

istioctl install \
  -f asm/cluster/istio-operator.yaml

### enabling subnet flow logs
gcloud compute networks subnets update default --region us-west1 \
    --enable-flow-logs

gcloud compute networks subnets describe default --region us-west1    

# cloud logging query
resource.type="gce_subnetwork"
logName="projects/kenthua-test-service-01/logs/compute.googleapis.com%2Fvpc_flows"
jsonPayload.connection.src_ip="10.4.0.6"
jsonPayload.connection.dest_ip="10.4.5.7"