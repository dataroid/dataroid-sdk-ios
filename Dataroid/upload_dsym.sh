#!/usr/bin/env bash

##
## Dataroid dSYM Upload Script
##
## Uploads the dSYM files produced by the current build to Dataroid so that
## crash stack traces can be symbolicated.
##
## The dSYM file is archived and uploaded directly to storage with a short lived
## upload URL, so it does not travel through the Dataroid service.
##
## Usage (Xcode Run Script Phase):
##   "path/to/upload_dsym.sh" "https://YOUR_SERVER_URL" "YOUR_SDK_KEY"
##
## This script never fails the build: it always exits with 0.
##

SCRIPT_VERSION="2.0.0"

LOG_FILE="/tmp/dataroid_upload_dsym.log"
UPLOAD_URL_PATH="/crash-service/upload-url/dsym"
REQUEST_TIMEOUT_SECONDS=300

##
## Logging
##

dataroid_log() {
    local MESSAGE="${1}"
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[Dataroid][${TIMESTAMP}]: ${MESSAGE}" | tee -a "${LOG_FILE}"
}

##
## Helpers
##

# Extracts a top level string value from a JSON payload without requiring jq.
json_string_value() {
    local JSON="${1}"
    local KEY="${2}"
    local VALUE

    VALUE=$(printf '%s' "${JSON}" | tr -d '\n' \
        | sed -n 's/.*"'"${KEY}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    # JSON encoders may escape forward slashes.
    printf '%s' "${VALUE}" | sed 's|\\/|/|g'
}

# Escapes a value so it can be embedded in a JSON string literal. Control
# characters are dropped rather than escaped: the value is only ever used as a
# display name, and a raw one would make the request body invalid JSON.
json_escape() {
    printf '%s' "${1}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Performs a single curl request. Writes the response body to $1 and echoes the
# HTTP status code (000 when the request could not be completed).
http_request() {
    local BODY_FILE="${1}"
    shift

    curl -sS -o "${BODY_FILE}" -w '%{http_code}' "$@" 2>>"${LOG_FILE}"
}

##
## Upload
##

# 1. POST the upload URL endpoint to obtain a short lived upload URL.
# 2. PUT the dSYM zip directly to storage.
# Returns 0 on success, 1 on failure.
upload_dsym() {
    local SERVER_URL="${1}"
    local SDK_KEY="${2}"
    local DSYM_ZIP_PATH="${3}"
    local UUIDS_CSV="${4}"
    local FILE_NAME="${5}"

    # Build the JSON array of UUIDs.
    local UUIDS_JSON
    UUIDS_JSON=$(printf '%s' "${UUIDS_CSV}" | tr ',' '\n' | grep . \
        | sed -e 's/^/"/' -e 's/$/",/' | tr -d '\n' | sed 's/,$//')

    local REQUEST_BODY
    REQUEST_BODY="{\"fileName\":\"$(json_escape "${FILE_NAME}")\",\"uuids\":[${UUIDS_JSON}]}"

    local REQUEST_URL="${SERVER_URL}${UPLOAD_URL_PATH}"
    local RESPONSE_FILE
    RESPONSE_FILE=$(mktemp -t dataroid_dsym_url)

    dataroid_log "Requesting an upload URL from ${REQUEST_URL} for ${FILE_NAME} with UUIDs: ${UUIDS_CSV}"

    local STATUS
    STATUS=$(http_request "${RESPONSE_FILE}" \
        -X POST "${REQUEST_URL}" \
        --max-time "${REQUEST_TIMEOUT_SECONDS}" \
        -H "x-appconnect-sdk-key: ${SDK_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data-binary "${REQUEST_BODY}")

    local RESPONSE
    RESPONSE=$(cat "${RESPONSE_FILE}" 2>/dev/null)
    rm -f "${RESPONSE_FILE}"

    # 409 means every UUID of this dSYM is already stored, which is a success.
    if [[ "${STATUS}" == "409" ]]; then
        dataroid_log "${FILE_NAME} is already uploaded for all of its UUIDs, nothing to do."
        return 0
    fi

    if [[ ${STATUS} != 2* ]]; then
        dataroid_log "Upload URL request failed for ${FILE_NAME}. Status: ${STATUS} Response: ${RESPONSE}"
        return 1
    fi

    local UPLOAD_URL
    local UPLOAD_ID
    local EXPIRES_AT
    UPLOAD_URL=$(json_string_value "${RESPONSE}" "url")
    UPLOAD_ID=$(json_string_value "${RESPONSE}" "uploadId")
    EXPIRES_AT=$(json_string_value "${RESPONSE}" "expiresAt")

    if [[ -z "${UPLOAD_URL}" ]]; then
        dataroid_log "Upload URL response did not contain a URL for ${FILE_NAME}. Response: ${RESPONSE}"
        return 1
    fi

    dataroid_log "Upload URL received for ${FILE_NAME}. uploadId: ${UPLOAD_ID} expiresAt: ${EXPIRES_AT}"

    local PUT_RESPONSE_FILE
    PUT_RESPONSE_FILE=$(mktemp -t dataroid_dsym_put)

    local PUT_STATUS
    PUT_STATUS=$(http_request "${PUT_RESPONSE_FILE}" \
        -X PUT "${UPLOAD_URL}" \
        --connect-timeout "${REQUEST_TIMEOUT_SECONDS}" \
        --speed-limit 1 \
        --speed-time "${REQUEST_TIMEOUT_SECONDS}" \
        -H "Content-Type: application/zip" \
        --upload-file "${DSYM_ZIP_PATH}")

    local PUT_RESPONSE
    PUT_RESPONSE=$(cat "${PUT_RESPONSE_FILE}" 2>/dev/null)
    rm -f "${PUT_RESPONSE_FILE}"

    if [[ ${PUT_STATUS} != 2* ]]; then
        dataroid_log "Direct upload failed for ${FILE_NAME}. Status: ${PUT_STATUS} Response: ${PUT_RESPONSE}"
        return 1
    fi

    dataroid_log "${FILE_NAME} uploaded successfully. uploadId: ${UPLOAD_ID} Status: ${PUT_STATUS}"
    dataroid_log "Validation and symbolication indexing continue asynchronously on the server."
    return 0
}

##
## Per dSYM pipeline: extract UUIDs, archive, upload.
##

process_dsym() {
    local SERVER_URL="${1}"
    local SDK_KEY="${2}"
    local DSYM_DIR="${3}"

    local DSYM_NAME
    DSYM_NAME=$(basename "${DSYM_DIR}")
    dataroid_log "Processing dSYM ${DSYM_NAME}"

    # Extracting build UUIDs from the dSYM using dwarfdump. A dSYM bundle can
    # hold more than one binary, and dwarfdump exits non-zero when any of them
    # cannot be read while still printing the UUIDs of the ones it could. Keep
    # those rather than dropping the whole dSYM.
    local DWARF_OUTPUT
    local DWARF_STATUS=0
    DWARF_OUTPUT=$(xcrun dwarfdump --uuid "${DSYM_DIR}" 2>>"${LOG_FILE}") || DWARF_STATUS=$?

    local BUILD_UUIDS
    BUILD_UUIDS=$(printf '%s\n' "${DWARF_OUTPUT}" \
        | awk '$1 == "UUID:" {print tolower($2)}' | grep . | sort -u | paste -sd ',' -)

    if [[ -z "${BUILD_UUIDS}" ]]; then
        dataroid_log "Extracting build UUIDs failed for ${DSYM_NAME}!"
        return 1
    fi

    if [[ ${DWARF_STATUS} -ne 0 ]]; then
        dataroid_log "dwarfdump could not read every binary in ${DSYM_NAME}, continuing with the UUIDs it did read."
    fi

    dataroid_log "Extracted build UUIDs for ${DSYM_NAME}: ${BUILD_UUIDS}"

    # Creating an archive that contains exactly one .dSYM bundle, as required by
    # the upload contract.
    local WORK_DIR
    WORK_DIR=$(mktemp -d -t dataroid_dsym)
    local DSYM_ZIP_PATH="${WORK_DIR}/${DSYM_NAME}.zip"

    if ! (cd "$(dirname "${DSYM_DIR}")" && zip -rq "${DSYM_ZIP_PATH}" "${DSYM_NAME}"); then
        dataroid_log "Creating archive failed for ${DSYM_NAME}!"
        rm -rf "${WORK_DIR}"
        return 1
    fi

    dataroid_log "Created archive at ${DSYM_ZIP_PATH}"

    local RESULT=0
    if ! upload_dsym "${SERVER_URL}" "${SDK_KEY}" "${DSYM_ZIP_PATH}" "${BUILD_UUIDS}" "${DSYM_NAME}.zip"; then
        RESULT=1
    fi

    rm -rf "${WORK_DIR}"
    return ${RESULT}
}

##
## Entry point
##

SERVER_URL="${1}"
SDK_KEY="${2}"

# Trailing slashes would produce a double slash in the request path.
SERVER_URL="${SERVER_URL%/}"

dataroid_log "Dataroid Upload Script (v${SCRIPT_VERSION}) Started..."

# Pre-checks
if [[ -z ${SERVER_URL} ]]; then
    dataroid_log "SERVER URL not found!"
    exit 0
fi

if [[ -z ${SDK_KEY} ]]; then
    dataroid_log "SDK KEY not found!"
    exit 0
fi

DSYM_FOLDER_PATH="${DWARF_DSYM_FOLDER_PATH}"

if [[ -z ${DSYM_FOLDER_PATH} ]]; then
    dataroid_log "Xcode Environment Variables are missing!"
    exit 0
fi

if [[ ! -d ${DSYM_FOLDER_PATH} ]]; then
    dataroid_log "dSYM folder ${DSYM_FOLDER_PATH} does not exist!"
    exit 0
fi

PROCESSED_COUNT=0

# Loop through all dSYM directories in the specified path and process in parallel.
for DSYM_DIR in "${DSYM_FOLDER_PATH}"/*.dSYM; do
    if [[ ! -d ${DSYM_DIR} ]]; then
        continue
    fi

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    process_dsym "${SERVER_URL}" "${SDK_KEY}" "${DSYM_DIR}" >/dev/null 2>>"${LOG_FILE}" &
done

if [[ ${PROCESSED_COUNT} -eq 0 ]]; then
    dataroid_log "No dSYM bundle found under ${DSYM_FOLDER_PATH}!"
    exit 0
fi

dataroid_log "Processing ${PROCESSED_COUNT} dSYM file(s). Upload will continue in background, see ${LOG_FILE} for the results."

exit 0
