#!/usr/bin/env bash

# Global log file variable
LOG_FILE="/tmp/dataroid_upload_dsym.log"

dataroid_log() {
    local MESSAGE="${1}"
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[Dataroid][${TIMESTAMP}]: ${MESSAGE}" | tee -a "${LOG_FILE}"
}

upload_dsym() {
    local SERVER_URL="${1}"
    local SDK_KEY="${2}"
    local DSYM_ZIP_PATH="${3}"
    local UUIDS="${4}"

    local ENDPOINT="/crash/dsym/uuid"
    local URL="${SERVER_URL}${ENDPOINT}"

    echo "${DSYM_ZIP_PATH} uploading to ${URL} with UUIDs: ${UUIDS}"

    local UPLOAD_RESULT=$(curl -s -S \
        -F "file=@${DSYM_ZIP_PATH};type=application/zip" \
        -F "uuids=${UUIDS}" "${URL}" \
        -H "x-appconnect-sdk-key: ${SDK_KEY}" \
        -H "Content-Type: multipart/form-data")
    
    local HTTP_STATUS=$(echo "${UPLOAD_RESULT}" | tail -n1)
    echo "[Dataroid]: dSYM upload completed. for: ${DSYM_ZIP_PATH} Result: ${HTTP_STATUS}"
}

# Reading arguments
SERVER_URL="${1}"
SDK_KEY="${2}"

dataroid_log "Dataroid Upload Script Started..."

# Pre-checks
if [[ -z $SERVER_URL ]]; then
    dataroid_log "SERVER URL not found!"
    exit 0
fi

if [[ -z $SDK_KEY ]]; then
    dataroid_log "SDK KEY not found!"
    exit 0
fi

if [ ! "${DWARF_DSYM_FOLDER_PATH}" ]; then
    dataroid_log "Xcode Environment Variables are missing!"
    exit 0
fi

# Loop through all dSYM directories in the specified path and process in parallel
for DSYM_DIR in "${DWARF_DSYM_FOLDER_PATH}"/*.dSYM; do
    if [[ ! -d $DSYM_DIR ]]; then
        dataroid_log "dSYM path ${DSYM_DIR} does not exist or is not a directory!"
        continue
    fi

    DSYM_NAME=$(basename "${DSYM_DIR}")
    dataroid_log "Processing dSYM ${DSYM_NAME}"

    # Extracting Build UUIDs from DSYM using dwarfdump
    BUILD_UUIDS=$(xcrun dwarfdump --uuid "${DSYM_DIR}" | awk '{print $2}' | xargs | sed 's/ /,/g')
    if [ $? -eq 0 ]; then
        dataroid_log "Extracted Build UUIDs: ${BUILD_UUIDS}"
    else
        dataroid_log "Extracting Build UUIDs failed for ${DSYM_NAME}!"
        continue
    fi

    # Creating archive of DSYM folder using zip
    DSYM_ZIP_PATH="/tmp/$(date +%s)_${DSYM_NAME}.zip"
    pushd "$(dirname "${DSYM_DIR}")" > /dev/null
    zip -rq "${DSYM_ZIP_PATH}" "${DSYM_NAME}"
    popd > /dev/null
    if [ $? -eq 0 ]; then
        dataroid_log "Created archive at ${DSYM_ZIP_PATH}"
        # Uploading in parallel
        upload_dsym "${SERVER_URL}" "${SDK_KEY}" "${DSYM_ZIP_PATH}" "${BUILD_UUIDS}" >> "${LOG_FILE}" 2>&1 &
    else
        dataroid_log "Creating archive failed for ${DSYM_NAME}!"
        continue
    fi
done

dataroid_log "All dSYM files processed. Upload will continue in background."
exit 0
