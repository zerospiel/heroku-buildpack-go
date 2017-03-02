#!/bin/bash

# -----------------------------------------
# load environment variables
# allow apps to specify cgo flags. The literal text '${build_dir}' is substituted for the build directory

if [ -z "${buildpack}" ]; then
    buildpack=$(cd "$(dirname $0)/.." && pwd)
fi

DataJSON="${buildpack}/data.json"
FilesJSON="${buildpack}/files.json"
godepsJSON="${build}/Godeps/Godeps.json"
vendorJSON="${build}/vendor/vendor.json"
glideYAML="${build}/glide.yaml"

BUILDPACK_LOG_FILE=${BUILDPACK_LOG_FILE:-/dev/null}
BPLOG_PREFIX="buildpack.go"

steptxt="----->"
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No Color
CURL="curl -s -L --retry 15 --retry-delay 2" # retry for up to 30 seconds

BucketURL="https://heroku-golang-prod.s3.amazonaws.com"

TOOL=""
# Default to $SOURCE_VERSION environment variable: https://devcenter.heroku.com/articles/buildpack-api#bin-compile
GO_LINKER_VALUE=${SOURCE_VERSION}


warn() {
    echo -e "${YELLOW} !!    $@${NC}"
}

err() {
    echo -e >&2 "${RED} !!    $@${NC}"
}

step() {
    echo "$steptxt $@"
}

start() {
    echo -n "$steptxt $@... "
}

finished() {
    echo "done"
}

determinLocalFileName() {
    local fileName="${1}"
    local localName="jq"
    if [ "${fileName}" != "jq-linux64" ]; then #jq is special cased here because we can't jq until we have jq'
        localName="$(<"${FilesJSON}" jq -r '."'${fileName}'".LocalName | if . == null then "'${fileName}'" else . end')"
    fi
    echo "${localName}"
}

downloadFile() {
    local fileName="${1}"
    local targetDir="${2}"
    local xCmd="${3}"
    local localName="$(determinLocalFileName "${fileName}")"
    local targetFile="${targetDir}/${localName}"

    mkdir -p "${targetDir}"
    pushd "${targetDir}" &> /dev/null
        start "Fetching ${localName}"
            let start=$(nowms)
            ${CURL} -O "${BucketURL}/${fileName}"
            mtime "download.${fileName}" "${start}"
            if [ "${fileName}" != "${localName}" ]; then
                mv "${fileName}" "${localName}"
            fi
            if [ -n "${xCmd}" ]; then
                ${xCmd} ${targetFile}
            fi
            if ! SHAValid "${fileName}" "${targetFile}"; then
                err ""
                err "Downloaded file (${fileName}) sha does not match recorded SHA"
                err "Unable to continue."
                err ""
                countExit "invalidSHA"
            fi
        finished
    popd &> /dev/null
}

SHAValid() {
    local fileName="${1}"
    local targetFile="${2}"
    local sh=""
    local sw="$(<"${FilesJSON}" jq -r '."'${fileName}'".SHA')"
    if [ ${#sw} -eq 40 ]; then
        sh="$(shasum "${targetFile}" | cut -d \  -f 1)"
    else
        sh="$(shasum -a256 "${targetFile}" | cut -d \  -f 1)"
    fi
    [ "${sh}" = "${sw}" ]
}

ensureFile() {
    local fileName="${1}"
    local targetDir="${2}"
    local xCmd="${3}"
    local localName="$(determinLocalFileName "${fileName}")"
    local targetFile="${targetDir}/${localName}"
    local download="false"
    if [ ! -f "${targetFile}" ]; then
        download="true"
    elif ! SHAValid "${fileName}" "${targetFile}"; then
        download="true"
    fi
    if [ "${download}" = "true" ]; then
        downloadFile "${fileName}" "${targetDir}" "${xCmd}"
    fi
}

addToPATH() {
    local targetDir="${1}"
    if echo "${PATH}" | grep -v "${targetDir}" &> /dev/null; then
        PATH="${targetDir}:${PATH}"
    fi
}

ensureInPath() {
    local fileName="${1}"
    local targetDir="${2}"
    local xCmd="${3:-chmod a+x}"
    local localName="$(determinLocalFileName "${fileName}")"
    local targetFile="${targetDir}/${localName}"
    addToPATH "${targetDir}"
    ensureFile "${fileName}" "${targetDir}" "${xCmd}"
}

loadEnvDir() {
    local env_dir="${1}"
    if [ ! -z "${env_dir}" ]; then
        mkdir -p "${env_dir}"
        env_dir=$(cd "${env_dir}/" && pwd)
        for key in CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS GO_LINKER_SYMBOL GO_LINKER_VALUE GO15VENDOREXPERIMENT GOVERSION GO_INSTALL_PACKAGE_SPEC GO_INSTALL_TOOLS_IN_IMAGE GO_SETUP_GOPATH_IN_IMAGE; do
            if [ -f "${env_dir}/${key}" ]; then
                export "${key}=$(cat "${env_dir}/${key}" | sed -e "s:\${build_dir}:${build}:")"
            fi
        done
    fi
}

setGoVersionFromEnvironment() {
    if [ -z "${GOVERSION}" ]; then
        warn ""
        warn "'GOVERSION' isn't set, defaulting to '${DefaultGoVersion}'"
        warn ""
        warn "Run 'heroku config:set GOVERSION=goX.Y' to set the Go version to use"
        warn "for future builds"
        warn ""
    fi
    ver=${GOVERSION:-$DefaultGoVersion}
}

determineTool() {
    if [ -f "${godepsJSON}" ]; then
        count "tool.godep"
        TOOL="godep"
        step "Checking Godeps/Godeps.json file."
        if ! jq -r . < "${godepsJSON}" > /dev/null; then
            err "Bad Godeps/Godeps.json file"
            countExit "badGodeps"
        fi
        name=$(<${godepsJSON} jq -r .ImportPath)
        ver=${GOVERSION:-$(<${godepsJSON} jq -r .GoVersion)}
        warnGoVersionOverride
    elif [ -f "${vendorJSON}" ]; then
        count "tool.govendor"
        TOOL="govendor"
        step "Checking vendor/vendor.json file."
        if ! jq -r . < "${vendorJSON}" > /dev/null; then
            err "Bad vendor/vendor.json file"
            bplog "$(<${vendorJSON})"
            countExit "badVendorJSON"
        fi
        name=$(<${vendorJSON} jq -r .rootPath)
        if [ "$name" = "null" -o -z "$name" ]; then
            err "The 'rootPath' field is not specified in 'vendor/vendor.json'."
            err "'rootPath' must be set to the root package name used by your repository."
            err "Recent versions of govendor add this field automatically, please upgrade"
            err "and re-run 'govendor init'."
            err ""
            err "For more details see: https://devcenter.heroku.com/articles/go-apps-with-govendor#build-configuration"
            countExit "govendor.json.missingRootPath"
        fi
        ver=${GOVERSION:-$(<${vendorJSON} jq -r .heroku.goVersion)}
        warnGoVersionOverride
        if [ "${ver}" =  "null" -o -z "${ver}" ]; then
            ver=${DefaultGoVersion}
            warn "The 'heroku.goVersion' field is not specified in 'vendor/vendor.json'."
            warn ""
            warn "Defaulting to ${ver}"
            warn ""
            warn "For more details see: https://devcenter.heroku.com/articles/go-apps-with-govendor#build-configuration"
            warn ""
        fi
    elif [ -f "${glideYAML}" ]; then
        count "tool.glide"
        TOOL="glide"
        setGoVersionFromEnvironment
    elif [ -d "$build/src" -a -n "$(find "$build/src" -mindepth 2 -type f -name '*.go' | sed 1q)" ]; then
        count "tool.gb"
        TOOL="gb"
        setGoVersionFromEnvironment
    else
        err "Godep, GB or govendor are required. For instructions:"
        err "https://devcenter.heroku.com/articles/go-support"
        countExit "unknownTool"
    fi
}

nowms() {
    date +%s%3N
}

countExit() {
    count "error.${1}"
    exit 1
}

bplog() {
  echo -n ${@} | awk 'BEGIN {printf "msg=\""; f="%s"} {gsub(/"/, "\\\"", $0); printf f, $0} {if (NR == 1) f="\\n%s" } END { print "\"" }' >> ${BUILDPACK_LOG_FILE}
}

mtime() {
    local key="${BPLOG_PREFIX}.${1}"
    local start="${2}"
    local end="${3:-$(nowms)}"
    echo "${key} ${start} ${end}" | awk '{ printf "measure#%s=%.3f\n", $1, ($3 - $2)/1000 }' >> ${BUILDPACK_LOG_FILE}
}

count() {
    local k=”${BPLOG_PREFIX}.${1}”
    local v=”${2:1}”
    echo “count#${k}=${v}” >> ${BUILDPACK_LOG_FILE}
}

measure() {
    local k=”${BPLOG_PREFIX}.${1}”
    local v=”${2}”
    echo “measure#${k}=${v}” >> ${BUILDPACK_LOG_FILE}
}

unique() {
    local k="${BPLOG_PREFIX}.${1}"
    local v=”${2}”
    echo "unique#${k}=${v}" >> ${BUILDPACK_LOG_FILE}
}
