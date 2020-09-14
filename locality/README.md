# Locality Load Balancing Setup 

## Setup
* Setup the cluster and install ASM
```
./run.sh
```

* Deploy the sample zoneprinter app
```
kubectl apply -f zoneprinter.yaml
```

* Deploy the sleep pod from the istio samples to use as the load generator
```
kubectl apply -f sleep.yaml
```

* Deploy applicable istio services, virtualservice not needed, but for completeness
```
kubectl apply -f destinationrule-zoneprinter.yaml
kubectl apply -f virtualserice-zoneprinter.yaml
```

* Testing
```
# This will run curl 15 times within the sleep pod
export SLEEP=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -c sleep $SLEEP -- /bin/sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do curl zoneprinter --silent; done | grep connected"

# This will run curl within the sleep pod, but exec in each time
for i in {1..15}
do 
  kubectl exec -it -c sleep $SLEEP -- /bin/sh -c "curl zoneprinter --silent | grep connected"
done
```