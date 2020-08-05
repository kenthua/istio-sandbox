# Istio replicated control plane failover, also remote secret for testing
Tested on Istio 1.6.7

## Cluster & Istio Setup
* Setup variables
```
export PROJECT_ID=kenthua-test-service-01
export SERVICE_ACCOUNT=project-service-account@${PROJECT_ID}.iam.gserviceaccount.com
export CLUSTER_1=istio-west
export CLUSTER_1_LOCATION=us-west1-a
export CLUSTER_2=istio-southeast
export CLUSTER_2_LOCATION=asia-southeast1-a
export ISTIOCTL_CMD=bin/istioctl
```

* Create clusters
```
gcloud container clusters create ${CLUSTER_1} \
  --project ${PROJECT_ID} \
  --service-account ${SERVICE_ACCOUNT} \
  --machine-type e2-standard-4 \
  --num-nodes 4 \
  --release-channel Regular \
  --zone ${CLUSTER_1_LOCATION} \
  --async

gcloud container clusters create ${CLUSTER_2} \
  --project ${PROJECT_ID} \
  --service-account ${SERVICE_ACCOUNT} \
  --machine-type e2-standard-4 \
  --num-nodes 4 \
  --release-channel Regular \
  --zone ${CLUSTER_2_LOCATION} \
  --async
```

* Install Istio -- need to be in istio folder
```
for i in ${CLUSTER_1} ${CLUSTER_2}
do
  kubectl create ns istio-system --context $i
  kubectl create secret generic cacerts --context $i -n istio-system \
  --from-file=samples/certs/ca-cert.pem \
  --from-file=samples/certs/ca-key.pem \
  --from-file=samples/certs/root-cert.pem \
  --from-file=samples/certs/cert-chain.pem
  ${ISTIOCTL_CMD} install -f manifests/examples/multicluster/values-istio-multicluster-gateways.yaml --context $i
done
```

## Remote Secret
* Setup remote secret sharing, use this when not wanting gateway between clusters -- REMOTE_SECRET
```
${ISTIOCTL_CMD} x create-remote-secret -n istio-system \
--context=${CLUSTER_1} \
--name=${CLUSTER_1} | \
kubectl apply -f - --context=${CLUSTER_2}

${ISTIOCTL_CMD} x create-remote-secret -n istio-system \
--context=${CLUSTER_2} \
--name=${CLUSTER_2} | \
kubectl apply -f - --context=${CLUSTER_1}

# Setup DNS for global -- REPLICATED_CONTROL_PLANE
for i in ${CLUSTER_1} ${CLUSTER_2}
do
  kubectl --context $i apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"global": ["$(kubectl get svc -n istio-system istiocoredns -o jsonpath={.spec.clusterIP})"]}
EOF
done
```

* Set sample app
```
kubectl create namespace sample --context=${CLUSTER_1}
kubectl label namespace sample istio-injection=enabled --context=${CLUSTER_1}
kubectl create namespace sample --context=${CLUSTER_2}
kubectl label namespace sample istio-injection=enabled --context=${CLUSTER_2}
kubectl create -f samples/helloworld/helloworld.yaml -l app=helloworld -n sample --context=${CLUSTER_1}
kubectl create -f samples/helloworld/helloworld.yaml -l version=v1 -n sample --context=${CLUSTER_1}
kubectl create -f samples/helloworld/helloworld.yaml -l app=helloworld -n sample --context=${CLUSTER_2}
kubectl create -f samples/helloworld/helloworld.yaml -l version=v2 -n sample --context=${CLUSTER_2}
kubectl apply -f samples/sleep/sleep.yaml -n sample --context=${CLUSTER_1}
kubectl apply -f samples/sleep/sleep.yaml -n sample --context=${CLUSTER_2}
export SLEEP1=$(kubectl get pod -n sample -l app=sleep --context=${CLUSTER_1} -o jsonpath='{.items[0].metadata.name}')
export SLEEP2=$(kubectl get pod -n sample -l app=sleep --context=${CLUSTER_2} -o jsonpath='{.items[0].metadata.name}')
```

* Get sample app information
```
${ISTIOCTL_CMD} --context $CLUSTER_1 -n sample pc ep $SLEEP1 | grep helloworld
${ISTIOCTL_CMD} --context $CLUSTER_2 -n sample pc ep $SLEEP2 | grep helloworld
```

* from CLUSTER_1
```
for i in {1..15}
  do kubectl exec -it -n sample -c sleep --context=${CLUSTER_1} $SLEEP1 -- curl helloworld.sample:5000/hello
done
```
* from CLUSTER_2
```
for i in {1..15}
  do kubectl exec -it -n sample -c sleep --context=${CLUSTER_2} $SLEEP2 -- curl helloworld.sample:5000/hello
done
```

## Replicated Control Plane & Failover
* Apply destination rule for failover
```
for i in ${CLUSTER_1} ${CLUSTER_2}
do
  kubectl apply --context ${i} -n sample -f manifests/destinationrule.yaml
done
```

* Service entry for both services
```
kubectl  apply -n sample --context ${CLUSTER_1} -f - << EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: helloworld-sample
spec:
  hosts:
  # must be of form name.namespace.global
  - helloworld.sample.global
  # Treat remote cluster services as part of the service mesh
  # as all clusters in the service mesh share the same root of trust.
  location: MESH_INTERNAL
  ports:
  - name: http
    number: 5000
    protocol: http
  resolution: DNS
  addresses:
  - 240.0.0.3
  endpoints:
  - address: helloworld.sample.svc.cluster.local
    locality: us-west1
    ports:
      http: 5000
  - address: $(kubectl --context=${CLUSTER_2} -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    locality: asia-southeast1
    ports:
      http: 15443 # Do not change this port value
EOF
```

* Test failover from CLUSTER_1 to CLUSTER_2
```
export SLEEP1=$(kubectl get pod -n sample -l app=sleep --context=${CLUSTER_1} -o jsonpath='{.items[0].metadata.name}')

for i in {1..15}
  do kubectl exec -it -n sample -c sleep --context=${CLUSTER_1} $SLEEP1 -- curl helloworld.sample.global:5000/hello
done
```

* Scale down and up to see behavior
```
kubectl scale deploy helloworld-v1  -n sample --context ${CLUSTER_1} --replicas=0
#wait
kubectl scale deploy helloworld-v1  -n sample --context ${CLUSTER_1} --replicas=1
```

===

## Not neeed for this use case
```
for i in ${CLUSTER_1} ${CLUSTER_2}
do
kubectl apply --context ${i} -n sample -f - << EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld
spec:
  hosts:
  - helloworld
  http:
  - route:
    - destination:
        host: helloworld
EOF
done
```