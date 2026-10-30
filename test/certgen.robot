*** Settings ***
Documentation     Unit suite for certgen/docker/lib.sh. Each test sources the
...               real lib.sh with an isolated CERTS_DIR and a stubbed
...               reload_nginx (the real one shells out to docker/nginx, which
...               unit scope must not touch). Render files are written by hand;
...               docker-gen rendering is covered by the e2e proxy.robot.
Library           Process
Library           OperatingSystem
Library           String
Suite Setup       Suite Temp Dir
Suite Teardown    Remove Directory    ${T}    recursive=True
Test Setup        Fresh State Dir

*** Variables ***
${LIB}                ${CURDIR}/../certgen/docker/lib.sh
${OUT}                ${CURDIR}/out
${GRACE}              2

*** Keywords ***
Suite Temp Dir
    ${r}=    Run Process    mktemp    -d    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0
    ${T}=    Strip String    ${r.stdout}
    Set Suite Variable    \${T}    ${T}
    Create Directory    ${OUT}

Fresh State Dir
    ${r}=    Run Process    mktemp    -d    -p    ${T}    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0
    ${D}=    Strip String    ${r.stdout}
    Create Directory    ${D}/certs
    Set Test Variable    \${CERTS_DIR}    ${D}/certs
    Set Test Variable    \${RENDER}    ${D}/render.txt
    Set Test Variable    \${MANIFEST}    ${D}/certs/.certgen.manifest
    Set Test Variable    \${PENDING}    ${D}/certs/.certgen.pending
    Set Test Variable    \${RELOAD_LOG}    ${D}/reloads
    Create File    ${RELOAD_LOG}    ${EMPTY}

Run Snippet
    [Documentation]    Source lib.sh with stubbed reload, run a snippet, return the result.
    [Arguments]    ${snippet}
    ${stub}=    Catenate
    ...    reload_nginx() { echo reloaded >> "${RELOAD_LOG}"; return 0; }
    ${script}=    Catenate    SEPARATOR=${\n}
    ...    . "${LIB}"
    ...    ${stub}
    ...    export CERTS_DIR="${CERTS_DIR}" RENDER_FILE="${RENDER}" GEN_REMOVAL_GRACE=${GRACE}
    ...    MANIFEST="${MANIFEST}" PENDING="${PENDING}" READY="${CERTS_DIR}/.certgen.ready"
    ...    ${snippet}
    ${r}=    Run Process    sh    -c    ${script}    timeout=60s
    RETURN    ${r}

Write Render
    [Arguments]    ${seen}    @{hosts}
    Run Process    printf '# certgen-desired v1\\n# containers-seen ${seen}\\n' > "${RENDER}"    shell=True    timeout=30s
    FOR    ${h}    IN    @{hosts}
        Run Process    echo ${h} >> "${RENDER}"    shell=True    timeout=30s
    END

Cert Subject
    [Arguments]    ${host}
    ${r}=    Run Process    openssl x509 -in "${CERTS_DIR}/${host}.crt" -noout -subject -ext subjectAltName    shell=True    timeout=30s
    Should Be Equal As Integers    ${r.rc}    0
    RETURN    ${r.stdout}

*** Test Cases ***
Valid Render Sorts And Dedupes
    Write Render    2    b.localhost    a.localhost    b.localhost
    ${r}=    Run Snippet    read_desired "$RENDER_FILE"
    Should Be Equal As Integers    ${r.rc}    0
    Should Be Equal    ${r.stdout}    a.localhost${\n}b.localhost

Render Without Sentinel Is Rejected
    Create File    ${RENDER}    no-sentinel\n
    ${r}=    Run Snippet    read_desired "$RENDER_FILE"
    Should Not Be Equal As Integers    ${r.rc}    0

Render With Zero Containers Seen Is Rejected
    Write Render    0
    ${r}=    Run Snippet    read_desired "$RENDER_FILE"
    Should Not Be Equal As Integers    ${r.rc}    0

Missing Render File Is Rejected
    ${r}=    Run Snippet    read_desired "${RENDER}/does-not-exist"
    Should Not Be Equal As Integers    ${r.rc}    0

Generated Cert Identity Matches Host
    ${r}=    Run Snippet    gen_cert_host unit.localhost
    Should Be Equal As Integers    ${r.rc}    0
    File Should Exist    ${CERTS_DIR}/unit.localhost.crt
    File Should Exist    ${CERTS_DIR}/unit.localhost.key
    ${subj}=    Cert Subject    unit.localhost
    Should Contain    ${subj}    unit.localhost

Regenerating An Existing Cert Is A No-Op
    ${r}=    Run Snippet    gen_cert_host unit.localhost
    Should Be Equal As Integers    ${r.rc}    0
    ${before}=    Get Modified Time    ${CERTS_DIR}/unit.localhost.crt
    ${r}=    Run Snippet    gen_cert_host unit.localhost
    Should Not Be Equal As Integers    ${r.rc}    0
    ${after}=    Get Modified Time    ${CERTS_DIR}/unit.localhost.crt
    Should Be Equal    ${after}    ${before}

Reserved Name ca Is Refused
    ${r}=    Run Snippet    gen_cert_host ca
    Should Not Be Equal As Integers    ${r.rc}    0
    File Should Not Exist    ${CERTS_DIR}/ca.crt

Full Reconcile Generates Missing Certs And Writes Manifest
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    File Should Exist    ${CERTS_DIR}/a.localhost.crt
    File Should Exist    ${CERTS_DIR}/b.localhost.crt
    ${manifest}=    Get File    ${MANIFEST}
    Should Be Equal    ${manifest}    a.localhost${\n}b.localhost${\n}

Stale Cert Is Kept And Pending Without Stalling
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    Write Render    1    a.localhost
    ${t0}=    Get Time    epoch
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    ${t1}=    Get Time    epoch
    Should Be Equal As Integers    ${r.rc}    0
    ${dt}=    Evaluate    ${t1} - ${t0}
    Should Be True    ${dt} < 10    msg=reconcile slept on grace (${dt}s)
    File Should Exist    ${CERTS_DIR}/b.localhost.crt
    ${pending}=    Get File    ${PENDING}
    Should Match Regexp    ${pending}    (?m)^[0-9]+ b\\.localhost$
    ${manifest}=    Get File    ${MANIFEST}
    Should Contain    ${manifest}    b.localhost

Re-Admitted Host Reuses Its Cert
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    Write Render    1    a.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    ${before}=    Get Modified Time    ${CERTS_DIR}/b.localhost.crt
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    ${after}=    Get Modified Time    ${CERTS_DIR}/b.localhost.crt
    Should Be Equal    ${after}    ${before}
    File Should Not Exist    ${PENDING}

Stale Cert Is Removed After Grace And Reload Fires
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    Write Render    1    a.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    ${reloads_before}=    Get File    ${RELOAD_LOG}
    Sleep    3s
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    File Should Not Exist    ${CERTS_DIR}/b.localhost.crt
    File Should Not Exist    ${CERTS_DIR}/b.localhost.key
    ${reloads_after}=    Get File    ${RELOAD_LOG}
    Should Not Be Equal    ${reloads_after}    ${reloads_before}
    ${manifest}=    Get File    ${MANIFEST}
    Should Not Contain    ${manifest}    b.localhost

Initial Reconcile Never Deletes
    Write Render    2    a.localhost    b.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    Write Render    1    a.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" initial
    Should Be Equal As Integers    ${r.rc}    0
    File Should Exist    ${CERTS_DIR}/b.localhost.crt
    ${manifest}=    Get File    ${MANIFEST}
    Should Contain    ${manifest}    b.localhost

Invalid Render Is A No-Op Success
    Write Render    1    a.localhost
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    Create File    ${RENDER}    garbage\n
    ${r}=    Run Snippet    reconcile "$RENDER_FILE" full
    Should Be Equal As Integers    ${r.rc}    0
    File Should Exist    ${CERTS_DIR}/a.localhost.crt
