*** Settings ***
Documentation     Proxy matrix: HTTP-only, self-signed HTTPS, and alt-port vhosts
...               against an isolated LAN-variant stack on remapped host ports.
Library           Process
Library           OperatingSystem
Library           String
Suite Setup       Start Test Stack
Suite Teardown    Stop Test Stack

*** Variables ***
${PROXY_DIR}          %{PROXY_DIR=${CURDIR}/..}
${PROJECT}            proxytest
${BACKEND_PROJECT}    proxytest-backends
${NETWORK}            proxytest-net
${HTTP_PORT}          18080
${HTTPS_PORT}         18443
${OUT}                ${CURDIR}/out
${COMPOSE}            docker compose -p ${PROJECT} -f ${PROXY_DIR}/docker-compose.yml -f ${PROXY_DIR}/docker-compose.lan.yml -f ${CURDIR}/compose.proxy-test.yml
${BACKEND_COMPOSE}    docker compose -p ${BACKEND_PROJECT} -f ${CURDIR}/compose.backends.yml

*** Keywords ***
Compose Env
    [Documentation]    Base env for every compose invocation.
    ${env}=    Create Dictionary
    ...    NGINX_PROXY_NETWORK=${NETWORK}
    ...    NGINX_PROXY_VERSION=1.11
    ...    CERT_DAYS=825
    ...    GEN_REMOVAL_GRACE=60
    ...    COMPOSE_IGNORE_ORPHANS=True
    RETURN    ${env}

Run Compose
    [Arguments]    @{args}
    ${env}=    Compose Env
    ${r}=    Run Process    @{args}    shell=True    env=${env}    timeout=300s
    ...    stdout=${OUT}/compose.log    stderr=STDOUT
    RETURN    ${r}

Start Test Stack
    Create Directory    ${OUT}
    ${r}=    Run Compose    ${COMPOSE} up -d --build
    Should Be Equal As Integers    ${r.rc}    0    msg=proxy up failed: ${r.stdout}
    ${r}=    Run Compose    ${BACKEND_COMPOSE} up -d --build
    Should Be Equal As Integers    ${r.rc}    0    msg=backends up failed
    Wait Until Keyword Succeeds    3 min    5 sec    Cert Exists For    robottls.localhost
    Wait Until Keyword Succeeds    3 min    5 sec    Cert Exists For    robotgrace.localhost
    Wait Until Keyword Succeeds    3 min    5 sec    HTTP Serves    robotplain.localhost    hello-plain

Stop Test Stack
    ${env}=    Compose Env
    Run Process    ${COMPOSE} logs --no-color > ${OUT}/proxy.log 2>&1    shell=True    env=${env}
    Run Process    ${BACKEND_COMPOSE} logs --no-color > ${OUT}/backends.log 2>&1    shell=True    env=${env}
    Run Process    ${BACKEND_COMPOSE} down -v    shell=True    env=${env}
    Run Process    ${COMPOSE} down -v    shell=True    env=${env}

Cert Exists For
    [Arguments]    ${host}
    ${r}=    Run Process
    ...    docker exec ${PROJECT}-certgen-1 test -f /certs/${host}.crt
    ...    shell=True    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0    msg=no cert for ${host} yet

Cert Gone For
    [Arguments]    ${host}
    ${r}=    Run Process
    ...    docker exec ${PROJECT}-certgen-1 test ! -f /certs/${host}.crt
    ...    shell=True    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0    msg=cert for ${host} still present

Curl
    [Arguments]    @{args}
    ${r}=    Run Process    curl    -sS    -m    15    @{args}    shell=True    timeout=60s
    RETURN    ${r}

HTTP Serves
    [Arguments]    ${host}    ${body}
    ${r}=    Curl    --resolve    ${host}:${HTTP_PORT}:127.0.0.1    http://${host}:${HTTP_PORT}/
    Should Be Equal As Integers    ${r.rc}    0    msg=curl failed: ${r.stderr}
    Should Contain    ${r.stdout}    ${body}

HTTPS Serves Insecure
    [Arguments]    ${host}    ${body}
    ${r}=    Curl    -k    --resolve    ${host}:${HTTPS_PORT}:127.0.0.1    https://${host}:${HTTPS_PORT}/
    Should Be Equal As Integers    ${r.rc}    0    msg=https failed: ${r.stderr}
    Should Contain    ${r.stdout}    ${body}

HTTP Redirects To HTTPS
    [Arguments]    ${host}
    ${r}=    Curl    -o    /dev/null    -w    \%{http_code} \%{redirect_url}
    ...    --resolve    ${host}:${HTTP_PORT}:127.0.0.1    http://${host}:${HTTP_PORT}/
    Should Be Equal As Integers    ${r.rc}    0    msg=http redirect failed: ${r.stderr}
    Should Contain    ${r.stdout}    301
    # Redirect target carries no port: the proxy sees its own 443, not the
    # test stack's remapped host port (production publishes 443:443, so the
    # bare https:// URL is exactly right there).
    Should Contain    ${r.stdout}    https://${host}/

*** Test Cases ***
HTTP-Only Vhost Serves Plain HTTP
    HTTP Serves    robotplain.localhost    hello-plain

HTTP-Only Vhost Has No Usable HTTPS
    ${r}=    Curl    --resolve    robotplain.localhost:${HTTPS_PORT}:127.0.0.1    https://robotplain.localhost:${HTTPS_PORT}/
    Should Not Be Equal As Integers    ${r.rc}    0

Cert Vhost Redirects HTTP To HTTPS
    HTTP Redirects To HTTPS    robottls.localhost
    HTTPS Serves Insecure    robottls.localhost    hello-tls

Self-Signed Cert Fails Verification Without Trust
    ${r}=    Curl    --resolve    robottls.localhost:${HTTPS_PORT}:127.0.0.1    https://robottls.localhost:${HTTPS_PORT}/
    Should Not Be Equal As Integers    ${r.rc}    0

Self-Signed Cert Identity Matches Vhost
    ${r}=    Run Process
    ...    openssl s_client -connect 127.0.0.1:${HTTPS_PORT} -servername robottls.localhost </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
    ...    shell=True    timeout=60s
    Should Be Equal As Integers    ${r.rc}    0
    Should Contain    ${r.stdout}    robottls.localhost

Alt-Port Backend Is Routed
    HTTP Redirects To HTTPS    robotalt.localhost
    HTTPS Serves Insecure    robotalt.localhost    hello-altport

Pending Grace Does Not Stall New Certs
    [Documentation]    Stopping an opted-in backend must not block cert
    ...    generation for other hosts: reconcile never sleeps on the lock.
    ...    (Regression test for the wedged docker-gen watch loop that
    ...    surfaced as SSL_ERROR_UNRECOGNIZED_NAME_ALERT.)
    Run Process    docker stop proxytest-hello-grace    shell=True    timeout=60s
    ${r}=    Run Compose    ${BACKEND_COMPOSE} up -d hello-stall
    Should Be Equal As Integers    ${r.rc}    0    msg=stall backend failed: ${r.stdout}
    Wait Until Keyword Succeeds    3 min    5 sec    Cert Exists For    robotstall.localhost
    HTTPS Serves Insecure    robotstall.localhost    hello-stall
    [Teardown]    Run Process    docker rm -f proxytest-hello-stall    shell=True    timeout=60s

Stale Cert Is Removed After Grace
    [Documentation]    A host that stays undesired past GEN_REMOVAL_GRACE
    ...    (60s in this stack) loses its cert; its HTTPS vhost stops working.
    Wait Until Keyword Succeeds    6 min    10 sec    Cert Gone For    robotgrace.localhost
    ${r}=    Curl    --resolve    robotgrace.localhost:${HTTPS_PORT}:127.0.0.1    https://robotgrace.localhost:${HTTPS_PORT}/
    Should Not Be Equal As Integers    ${r.rc}    0
