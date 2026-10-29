*** Settings ***
Documentation     Upload limits: MAX_BODY_SIZE opt-in, global default, invalid values.
...               Isolated stack on remapped host ports; leaves no residue.
Library           Process
Library           OperatingSystem
Suite Setup       Start Maxbody Stack
Suite Teardown    Stop Maxbody Stack

*** Variables ***
${PROXY_DIR}          %{PROXY_DIR=${CURDIR}/..}
${PROJECT}            proxytest2
${BACKEND_PROJECT}    proxytest2-backends
${NETWORK}            proxytest2-net
${HTTP_PORT}          18080
${OUT}                ${CURDIR}/out
${COMPOSE}            docker compose -p ${PROJECT} -f ${PROXY_DIR}/docker-compose.yml -f ${PROXY_DIR}/docker-compose.lan.yml -f ${CURDIR}/compose.proxy-test.yml
${BACKEND_COMPOSE}    docker compose -p ${BACKEND_PROJECT} -f ${CURDIR}/compose.maxbody-backends.yml
${BIG_FILE}           ${OUT}/big-12m.bin

*** Keywords ***
Compose Env
    ${env}=    Create Dictionary
    ...    NGINX_PROXY_NETWORK=${NETWORK}
    ...    NGINX_PROXY_VERSION=1.11
    ...    CERT_DAYS=825
    ...    GEN_REMOVAL_GRACE=86400
    ...    COMPOSE_IGNORE_ORPHANS=True
    RETURN    ${env}

Run Compose
    [Arguments]    @{args}
    ${env}=    Compose Env
    ${r}=    Run Process    @{args}    shell=True    env=${env}    timeout=300s
    ...    stdout=${OUT}/maxbody-compose.log    stderr=STDOUT
    RETURN    ${r}

Start Maxbody Stack
    Create Directory    ${OUT}
    Run Keyword    Make Big File
    ${r}=    Run Compose    ${COMPOSE} up -d --build
    Should Be Equal As Integers    ${r.rc}    0    msg=proxy up failed: ${r.stdout}
    ${env}=    Compose Env
    ${r}=    Run Process    ${BACKEND_COMPOSE} up -d --build    shell=True    env=${env}    timeout=300s
    Should Be Equal As Integers    ${r.rc}    0    msg=backends up failed
    Wait Until Keyword Succeeds    3 min    5 sec    Vhost File Exists    robotbig.localhost    client_max_body_size 50m;

Stop Maxbody Stack
    ${env}=    Compose Env
    Run Process    ${COMPOSE} logs --no-color > ${OUT}/maxbody-proxy.log 2>&1    shell=True    env=${env}
    Run Process    ${BACKEND_COMPOSE} logs --no-color > ${OUT}/maxbody-backends.log 2>&1    shell=True    env=${env}
    Run Process    ${BACKEND_COMPOSE} down -v    shell=True    env=${env}
    Run Process    ${COMPOSE} down -v    shell=True    env=${env}

Make Big File
    Run Process    truncate -s 12M ${BIG_FILE}    shell=True    timeout=60s

Vhost File Exists
    [Arguments]    ${host}    ${content}
    ${r}=    Run Process    docker exec ${PROJECT}-maxbody-1 cat /vhostd/${host}    shell=True    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0    msg=no vhost file for ${host} yet
    Should Contain    ${r.stdout}    ${content}

Vhost File Missing
    [Arguments]    ${host}
    ${r}=    Run Process    docker exec ${PROJECT}-maxbody-1 test -f /vhostd/${host}    shell=True    timeout=30s
    Should Not Be Equal As Integers    ${r.rc}    0    msg=vhost file for ${host} still present

Upload
    [Arguments]    ${host}    ${file}    ${expected_rc}=0
    ${r}=    Run Process    curl    -sS    -m    60    --fail
    ...    --resolve    ${host}:${HTTP_PORT}:127.0.0.1
    ...    --data-binary    @${file}    http://${host}:${HTTP_PORT}/
    ...    -o    /dev/null    shell=True    timeout=120s
    Should Be Equal As Integers    ${r.rc}    ${expected_rc}    msg=curl: ${r.stderr}

*** Test Cases ***
Opted-In Vhost File Is Rendered
    Vhost File Exists    robotbig.localhost    client_max_body_size 50m;

Opted-In Vhost Accepts 12M Upload
    Upload    robotbig.localhost    ${BIG_FILE}    0

Default Vhost Rejects 12M Upload With 413
    Upload    robotdef.localhost    ${BIG_FILE}    22

Default Vhost Accepts Small Upload
    ${small}=    Set Variable    ${OUT}/small.txt
    Create File    ${small}    hello
    Upload    robotdef.localhost    ${small}    0

Invalid Size Is Ignored And Falls Back To Default
    Vhost File Missing    robotbogus.localhost
    Upload    robotbogus.localhost    ${BIG_FILE}    22

Removed Backend Loses Its Limit File
    [Documentation]    Stopping the backend removes its vhost file on the next reconcile.
    ${env}=    Compose Env
    Run Process    docker stop proxytest2-hello-big    shell=True    timeout=60s
    Wait Until Keyword Succeeds    2 min    5 sec    Vhost File Missing    robotbig.localhost
