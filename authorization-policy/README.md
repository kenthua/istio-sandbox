# Istio authz Policy JWT North/South, Istio Authn/Authz East/West

- Setup the environment
    ```
    export PROJECT_ID=your_project_id
    export ASM_REV=asm-1104-14
    export GATEWAY_NAMESPACE=istio-ingress
    ISTIO_HOME=${HOME}/work/istio-${ASM_REV}
    envsubst <namespace-foo.yaml_tmpl > namespace-foo.yaml
    alias k=kubectl
    k apply -f namespace-foo.yaml
    k apply -n foo -f${ISTIO_HOME}/samples/httpbin/httpbin.yaml
    k apply -n foo -f gateway.yaml
    k apply -n foo -f virtualservice.yaml
    k apply -f requestauthentication.yaml
    k apply -f ap-require-valid-token.yaml
    ```

    ```
    export INGRESS_HOST=$(kubectl -n ${GATEWAY_NAMESPACE} get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    export INGRESS_PORT=$(kubectl -n ${GATEWAY_NAMESPACE} get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
    ```

- Enable rbac debug so we can observe the behavior of the ingress gateway (new window)
    ```
    istioctl pc log deploy/istio-ingressgateway -n ${GATEWAY_NAMESPACE} --level rbac:debug
    k logs -f -l istio=ingressgateway -n ${GATEWAY_NAMESPACE}
    ```

- When it all works (HTTP 200)
    ```
    TOKEN=$(curl https://raw.githubusercontent.com/istio/istio/release-1.10/security/tools/jwt/samples/demo.jwt -s)
    curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"
    ```

- When it doesn't work, because we require a valid principal and jwt token (HTTP 401)
    ```
    curl --header "Authorization: Bearer Blah" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"
    ```

- Get some logs from httpbin (new window)
    ```
    istioctl pc log deploy/httpbin -n foo --level rbac:debug
    k logs -f -l app=httpbin -n foo -c istio-proxy
    ```

- Apply a rule to require a JWT requestPrincipal.  (HTTP 403) Check the httpbin istio proxy logs.  
    - Ingress gateway allows the call because a valid JWT with requestPrincipal are provided
    - Application/service (httpbin) denies because the JWT is not propagated, instead we get the istio source principal (service account)
    ```
    k apply -f ap-require-valid-token-app-jwt-fail.yaml

    curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"
    ```

    ```
    ...output...
    # C=US";URI=spiffe://kenthua-test-standalone.svc.id.goog/ns/istio-ingress/sa/istio-ingressgateway'
    # , dynamicMetadata: filter_metadata {
    #   key: "istio_authn"
    #   value {
    #     fields {
    #       key: "source.namespace"
    #       value {
    #         string_value: "istio-ingress"
    #       }
    #     }
    #     fields {
    #       key: "source.principal"
    #       value {
    #         string_value: "kenthua-test-standalone.svc.id.goog/ns/istio-ingress/sa/istio-ingressgateway"
    #       }
    #     }
    #     fields {
    #       key: "source.user"
    #       value {
    #         string_value: "kenthua-test-standalone.svc.id.goog/ns/istio-ingress/sa/istio-ingressgateway"
    #       }
    #     }
    #   }
    # }
    ```

- Apply the rule to allow allow all principals (i.e. istio source principal) (HTTP 200)
    ```
    k apply -f ap-require-valid-token-app-istioauth-all-allow.yaml

    curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"
    ```

- Apply the rule to allow only the istio source principal (service account) of the istio ingressgateway, see the rule match (give it some time to replicate) (HTTP 200)
    ```
    envsubst <ap-require-valid-token-app-istioauth-all-allow-ingress.yaml_tmpl > ap-require-valid-token-app-istioauth-all-allow-ingress.yaml
    k apply -f ap-require-valid-token-app-istioauth-all-allow-ingress.yaml

    curl --header "Authorization: Bearer $TOKEN" "$INGRESS_HOST:$INGRESS_PORT/headers" -s -o /dev/null -w "%{http_code}\n"
    ```

- Deploy sleep pod to invoke a call to httpbin
    ```
    k apply -f ${ISTIO_HOME}/samples/sleep/sleep.yaml -n foo
    ```

- The sleep pod is denied, the rule we previously applied allowed only the istio source principal from the ingress gateway (HTTP 403)
    ```
    k exec "$(k get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})" -c sleep -n foo -- curl -H "Authorization: Bearer ${TOKEN}" "http://httpbin.foo:8000/headers" -sS -o /dev/null -w "%{http_code}\n"
    ```

> NOTE: By default the jwt token is not forwarded, however the `RequestAuthentication` `jwtRules.forwardOriginalToken` can be set to `true` which would forward the jwt token to the workload.  As a result you can authz with jwt rather than the k8s service account.

- Cleanup
    ```
    k delete -n foo -f ${ISTIO_HOME}/samples/sleep/sleep.yaml
    k delete -n foo -f ${ISTIO_HOME}/samples/httpbin/httpbin.yaml
    k delete -n foo -f gateway.yaml
    k delete -n foo -f virtualservice.yaml
    k delete -f namespace-foo.yaml
    k delete -f requestauthentication.yaml
    k delete -f ap-require-valid-token.yaml
    ```