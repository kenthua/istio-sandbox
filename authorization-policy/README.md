# Istio authz Policy JWT North/South, Istio Authn/Authz East/West
## Note the [dry-run](https://cloud.google.com/service-mesh/docs/security/authorization-advanced-features) option for testing

- Setup the environment
    ```
    export PROJECT_ID=your_project_id
    export ASM_REV=asm-1112-17
    export ISTIO_VERSION=1.11.2-asm.17
    export GATEWAY_NAMESPACE=istio-ingress-general
    ISTIO_HOME=${HOME}/work/istio-${ISTIO_VERSION}
    envsubst <namespace-foo.yaml_tmpl > namespace-foo.yaml
    alias k=kubectl
    k apply -f namespace-foo.yaml
    k apply -n foo -f ${ISTIO_HOME}/samples/httpbin/httpbin.yaml
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
    ${ISTIO_HOME}/bin/istioctl pc log deploy/istio-ingressgateway -n ${GATEWAY_NAMESPACE} --level rbac:debug
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
    ${ISTIO_HOME}/bin/istioctl pc log deploy/httpbin -n foo --level rbac:debug
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
    ...httpbin output...
    2021-10-21T23:01:51.552202Z     debug   envoy rbac      checking request: requestedServerName: outbound_.8000_._.httpbin.foo.svc.cluster.local, sourceIP: 10.108.1.15:40304, directRemoteIP: 10.108.1.15:40304, remoteIP: 10.128.0.40:0,localAddress: 10.108.9.5:80, ssl: uriSanPeerCertificate: spiffe://kenthua-test-standalone.svc.id.goog/ns/istio-ingress-general/sa/istio-ingressgateway, dnsSanPeerCertificate: , subjectPeerCertificate: OU=istio_v1_cloud_workload,O=Google LLC,L=Mountain View,ST=California,C=US, headers: ':authority', '35.222.xxx.xxx'
    ':path', '/headers'
    ':method', 'GET'
    ':scheme', 'http'
    'user-agent', 'curl/7.64.0'
    'accept', '*/*'
    'x-forwarded-for', '10.128.0.40'
    'x-forwarded-proto', 'http'
    'x-request-id', '534b5a58-452f-4a27-aa09-8d470100b925'
    'x-envoy-attempt-count', '1'
    'x-b3-traceid', 'eedcff4f293546d0df72b62091133164'
    'x-b3-spanid', 'df72b62091133164'
    'x-b3-sampled', '0'
    'x-envoy-internal', 'true'
    'x-forwarded-client-cert', 'By=spiffe://kenthua-test-standalone.svc.id.goog/ns/foo/sa/httpbin;Hash=7dc82ee29a9e84bb660cbbe092369552a2c934e19ff8b6641b85a683e9a40324;Subject="OU=istio_v1_cloud_workload,O=Google LLC,L=Mountain View,ST=California,C=US";URI=spiffe://kenthua-test-standalone.svc.id.goog/ns/istio-ingress-general/sa/istio-ingressgateway'
    , dynamicMetadata: filter_metadata {
    key: "istio_authn"
    value {
    }
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

    > NOTE: The source principal configured is `"${PROJECT_ID}.svc.id.goog/ns/${GATEWAY_NAMESPACE}/sa/istio-ingressgateway"`, validate your service acccount is consistent with the template.

- Deploy sleep pod to invoke a call to httpbin
    ```
    k apply -f ${ISTIO_HOME}/samples/sleep/sleep.yaml -n foo
    ```

- The sleep pod is technically denied, but we enabled dry-run so it still passes, but is logged.  The rule we previously applied allowed only the istio source principal from the ingress gateway (HTTP 200)
    ```
    k exec "$(k get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})" -c sleep -n foo -- curl -H "Authorization: Bearer ${TOKEN}" "http://httpbin.foo:8000/headers" -sS -o /dev/null -w "%{http_code}\n"
    ```

    > NOTE: By default the jwt token is not forwarded, however the `RequestAuthentication` `jwtRules.forwardOriginalToken` can be set to `true` which would forward the jwt token to the workload.  As a result you can authz with jwt rather than the k8s service account.  Propagating token is not always ideal in all scenarios.  In most cases, each service should request it's own JWT token.

- Dry-run of the authorization policy is enabled via annotation `metadata.annotations.istio.io/dry-run=true`.  The call passed, but notice the failure in the label.
    ```
    gcloud logging read --project ${PROJECT_ID} \
        "logName="projects/${PROJECT_ID}/logs/server-accesslog-stackdriver" AND labels.destination_namespace="foo" AND labels.source_namespace="foo""
    ```

    ```
    labels:
      ...
      dry_run_result: AuthzDenied
      ...
    ```

- To enforce it, disable the dry-run annotation. (HTTP 403)
    ```
    sed -i "s/dry-run\": \"true\"/dry-run\": \"false\"/" ap-require-valid-token-app-istioauth-all-allow-ingress.yaml

    k apply -f  ap-require-valid-token-app-istioauth-all-allow-ingress.yaml

    k exec "$(k get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})" -c sleep -n foo -- curl -H "Authorization: Bearer ${TOKEN}" "http://httpbin.foo:8000/headers" -sS -o /dev/null -w "%{http_code}\n"
    ```

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
