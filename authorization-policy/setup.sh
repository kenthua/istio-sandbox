ISTIO_HOME=${HOME}/work/istio-1.9.5-asm.2
k apply -f ${ISTIO_HOME}/samples/httpbin/httpbin.yaml
k apply -f namespace-foo.yaml
k apply -f gateway.yaml
k apply -f virtualservice.yaml
k apply -f ap-require-valid-token.yaml

export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
export TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')

istioctl pc log deploy/istio-ingressgateway -n istio-system --level rbac:debug
k logs -f -l istio=ingressgateway -n istio-system

# good
TOKEN=$(curl https://raw.githubusercontent.com/istio/istio/release-1.10/security/tools/jwt/samples/demo.jwt -s)
curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"

# bad
curl --header "Authorization: Bearer Blah" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"

istioctl pc log deploy/httpbin -n foo --level rbac:debug
k logs -f -l app=httpbin -n foo -c istio-proxy

# notice when applying at the application it denies because the jwt is not propagated and identity is now different
k apply -f ap-require-valid-token-app-jwt-fail.yaml
curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"

...output...
# C=US";URI=spiffe://kenthua-test-standalone.svc.id.goog/ns/istio-system/sa/istio-ingressgateway-service-account'
# , dynamicMetadata: filter_metadata {
#   key: "istio_authn"
#   value {
#     fields {
#       key: "source.namespace"
#       value {
#         string_value: "istio-system"
#       }
#     }
#     fields {
#       key: "source.principal"
#       value {
#         string_value: "kenthua-test-standalone.svc.id.goog/ns/istio-system/sa/istio-ingressgateway-service-account"
#       }
#     }
#     fields {
#       key: "source.user"
#       value {
#         string_value: "kenthua-test-standalone.svc.id.goog/ns/istio-system/sa/istio-ingressgateway-service-account"
#       }
#     }
#   }
# }

# let's use istio auth
k apply -f ap-require-valid-token-app-istioauth-all-allow.yaml

curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"

# let's allow only from ingressgateway - see the match
k apply -f ap-require-valid-token-app-istioauth-all-allow-ingress.yaml

curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"

k apply -f ${ISTIO_HOME}/samples/sleep/sleep.yaml -n foo

# see how sleep is denied
k exec "$(k get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})" -c sleep -n foo -- curl -H "Authorization: Bearer ${TOKEN}" "http://httpbin.foo:8000/headers" -sS -o /dev/null -w "%{http_code}\n"

k delete -f ${ISTIO_HOME}/samples/sleep/sleep.yaml -n foo
