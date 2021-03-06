#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

#
# This is a library for the DC functions.
#

# Important! This is just a place-holder until we rewrite in node.
#

source /lib/sdc/config.sh
load_sdc_config

if [[ $1 == "--no-headers" ]]; then
    CURL_OPTS="-m 10 -sS -H accept:application/json"
    shift
else
    # BASHSTYLED
    CURL_OPTS="-m 10 -sS -i -H accept:application/json -H content-type:application/json"
fi

# CNAPI!
CNAPI_URL="http://${CONFIG_cnapi_domain}"

# VMAPI!
VMAPI_URL="http://${CONFIG_vmapi_domain}"

# NAPI!
NAPI_URL="http://${CONFIG_napi_domain}"

# FWAPI!
FWAPI_URL="http://${CONFIG_fwapi_domain}"

# WORKFLOW!
WORKFLOW_URL="http://${CONFIG_workflow_domain}"

# SAPI!
SAPI_URL="http://${CONFIG_sapi_domain}"

fatal()
{
    echo "$@" >&2
    exit 1
}

cnapi()
{
    path=$1
    shift
    (curl ${CURL_OPTS} --url "${CNAPI_URL}${path}" \
        "$@") || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

napi()
{
    path=$1
    shift
    (curl ${CURL_OPTS} --url "${NAPI_URL}${path}" \
        "$@") || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

fwapi()
{
    path=$1
    shift

    # Some SAPI calls can take much longer, so raise the timeout to two minutes.
    CURL_OPTS=${CURL_OPTS/10/120}

    (curl ${CURL_OPTS} --url "${FWAPI_URL}${path}" \
        "$@") || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

sapi()
{
    path=$1
    shift
    # Want a longer max-time (-m) for SAPI's CreateInstance: one hour.
    curl ${CURL_OPTS} -m 3600 --url "${SAPI_URL}${path}" \
        "$@" || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

workflow()
{
    path=$1
    shift
    (curl ${CURL_OPTS} --url \
        "${WORKFLOW_URL}${path}" "$@") || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

vmapi()
{
    path=$1
    shift
    curl ${CURL_OPTS} --url "${VMAPI_URL}${path}" \
        "$@" || return $?
    echo ""  # sometimes the result is not terminated with a newline
    return 0
}

# filename passed must have a 'Job-Location: ' header in it.
watch_job()
{
    local filename=$1

    # This may in fact be the hackiest possible way I could think up to do this
    rm -f /tmp/job_status.$$.old
    touch /tmp/job_status.$$.old
    local prev_execution=
    local chain_results=
    local execution="unknown"
    local job_status=
    local loop=0
    local output=
    local http_result=
    local http_code=
    local http_message=

    local job
    job=$(json -H job_uuid < ${filename})
    if [[ -z ${job} ]]; then
        # BASHSTYLED
        echo "+ FAILED! Result has no Job-Location: header. See ${filename}." >&2
        return 2
    fi

    echo "+ Job is /jobs/${job}"

    while [[ ${execution} == "running" || ${execution} == "queued" || \
        ${execution} == "unknown" ]] \
        && [[ ${loop} -lt 120 ]]; do

        local output
        output=$(workflow /jobs/${job})
        local http_result
        http_result=$(echo "${output}" | \
            grep "^HTTP/1.1 [0-9][0-9][0-9] " | tail -1)
        local http_code
        http_code=$(echo "${http_result}" | cut -d' ' -f2)
        local http_message
        http_message=$(echo "${http_result}" | cut -d' ' -f3-)

        if echo "${http_code}" | grep "^[45]" >/dev/null; then
            # BASHSTYLED
            echo "+ Failed to get status (will retry), workflow said: ${http_code} ${http_message}"
        else
            job_status=$(echo "${output}" | json -H)
            echo "${job_status}" | json chain_results | json -a result \
                > /tmp/job_status.$$.new
            diff -u /tmp/job_status.$$.old /tmp/job_status.$$.new | \
                grep -v "No differences encountered" | grep "^+[^+]" | \
                sed -e "s/^+/+ /"
            mv /tmp/job_status.$$.new /tmp/job_status.$$.old
            execution=$(echo "${job_status}" | json execution)
            if [[ ${execution} != ${prev_execution} ]]; then
                echo "+ Job status changed to: ${execution}"
                prev_execution=${execution}
            fi
        fi
        sleep 0.5
    done

    if [[ ${execution} == "succeeded" ]]; then
        echo "+ Success!"
        return 0
    elif [[ ${execution} == "canceled" ]]; then
        echo "+ CANCELED! (details in /jobs/${job})" >&2
        return 1
    else
        echo "+ FAILED! (details in /jobs/${job})" >&2
        return 1
    fi
}

provision_zone_from_payload()
{
    local tmpfile=$1
    local verbose="$2"

    vmapi /vms -X POST -H "Content-Type: application/json" \
        --data-binary @${tmpfile} >/tmp/provision.$$ 2>&1
    return_code=$?
    if [[ ${return_code} != 0 ]]; then
        echo "VMAPI FAILED with:" >&2
        cat /tmp/provision.$$ >&2
        return ${return_code}
    fi
    provisioned_uuid=$(json -H vm_uuid < /tmp/provision.$$)
    if [[ -z ${provisioned_uuid} ]]; then
        if [[ -n $verbose ]]; then
            # BASHSTYLED
            echo "+ FAILED: Unable to get uuid for new ${zrole} VM (see /tmp/provision.$$)."
            cat /tmp/provision.$$ | json -H
            exit 1
        else
            # BASHSTYLED
            fatal "+ FAILED: Unable to get uuid for new ${zrole} VM (see /tmp/provision.$$)."
        fi
    fi

    echo "+ Sent provision to VMAPI for ${provisioned_uuid}"
    watch_job /tmp/provision.$$

    return $?
}
