#!/usr/bin/env bash

[[ -z ${API_KEY} ]] && echo "API_KEY not defined, exiting!" && exit 1
[[ -z ${GITLAB_SERVER} ]] && GITLAB_SERVER="dumps.tadiphone.dev"
[[ -z ${PUSH_HOST} ]] && PUSH_HOST="dumps"
[[ -z $ORG ]] && ORG="dumps"
[[ -z ${USE_ALT_DUMPER} ]] && USE_ALT_DUMPER="false"

CHAT_ID="-1001412293127"

# usage: normal - sendTg normal "message to send"
#        reply  - sendTg reply message_id "reply to send"
#        edit   - sendTg edit message_id "new message" ( new message must be different )
# Uses global var API_KEY
sendTG() {
    local mode="${1:?Error: Missing mode}" && shift
    local api_url="https://api.telegram.org/bot${API_KEY:?}"
    if [[ ${mode} =~ normal ]]; then
        curl --compressed -s "${api_url}/sendmessage" --data "text=$(urlEncode "${*:?Error: Missing message text.}")&chat_id=${CHAT_ID:?}&parse_mode=HTML"
    elif [[ ${mode} =~ reply ]]; then
        local message_id="${1:?Error: Missing message id for reply.}" && shift
        curl --compressed -s "${api_url}/sendmessage" --data "text=$(urlEncode "${*:?Error: Missing message text.}")&chat_id=${CHAT_ID:?}&parse_mode=HTML&reply_to_message_id=${message_id}"
    elif [[ ${mode} =~ edit ]]; then
        local message_id="${1:?Error: Missing message id for edit.}" && shift
        curl --compressed -s "${api_url}/editMessageText" --data "text=$(urlEncode "${*:?Error: Missing message text.}")&chat_id=${CHAT_ID:?}&parse_mode=HTML&message_id=${message_id}"
    fi
}

# usage: temporary - To just edit the last message sent but the new content will be overwritten when this function is used again
#                    sendTG_edit_wrapper temporary "${MESSAGE_ID}" new message
#        permanent - To edit the last message sent but also store it permanently, new content will be appended when this function is used again
#                    sendTG_edit_wrapper permanent "${MESSAGE_ID}" new message
# Uses global var MESSAGE for all message contents
sendTG_edit_wrapper() {
    local mode="${1:?Error: Missing mode}" && shift
    local message_id="${1:?Error: Missing message id variable}" && shift
    case "${mode}" in
        temporary) sendTG edit "${message_id}" "${*:?}" > /dev/null ;;
        permanent)
            MESSAGE="${*:?}"
            sendTG edit "${message_id}" "${MESSAGE}" > /dev/null
            ;;
    esac
}

# reply to the initial message sent to the group with "Job Done" or "Job Failed!" accordingly
# 1st arg should be either 1 ( error ) or 0 ( success )
terminate() {
    if [[ ${1:?} == "0" ]]; then
        local string="Done (<a href=\"${BUILD_URL}\">#${BUILD_ID}</a>)"
    else
        local string="Failed! (<a href=\"${BUILD_URL}\">\"#${BUILD_ID}\"</a>)
View <a href=\"${BUILD_URL}consoleText\">console logs</a> for more."
    fi
    sendTG reply "${MESSAGE_ID}" "Job ${string}"
    exit "${1:?}"
}

# https://github.com/dylanaraps/pure-bash-bible#percent-encode-a-string
urlEncode() {
    declare LC_ALL=C
    for ((i = 0; i < ${#1}; i++)); do
        : "${1:i:1}"
        case "${_}" in
            [a-zA-Z0-9.~_-])
                printf '%s' "${_}"
                ;;
            *)
                printf '%%%02X' "'${_}"
                ;;
        esac
    done 2>| /dev/null
    printf '\n'
}

curl --compressed --fail-with-body --silent --location "https://$GITLAB_SERVER" > /dev/null || {
    sendTG normal "Can't access $GITLAB_SERVER, cancelling job!"
    exit 1
}

if [[ -f $URL ]]; then
    cp -v "$URL" .
    MESSAGE="<code>Found file locally.</code>"
    if _json="$(sendTG normal "${MESSAGE}")"; then
        # grab initial message id
        MESSAGE_ID="$(jq ".result.message_id" <<< "${_json}")"
    else
        # disable sendTG and sendTG_edit_wrapper if wasn't able to send initial message
        sendTG() { :; } && sendTG_edit_wrapper() { :; }
    fi
else
    MESSAGE="<code>Started</code> <a href=\"${URL}\">dump</a> <code>on</code> <a href=\"$BUILD_URL\">jenkins</a>
<b>Job ID:</b> <code>$BUILD_ID</code>."
    if _json="$(sendTG normal "${MESSAGE}")"; then
        # grab initial message id
        MESSAGE_ID="$(jq ".result.message_id" <<< "${_json}")"
    else
        # disable sendTG and sendTG_edit_wrapper if wasn't able to send initial message
        sendTG() { :; } && sendTG_edit_wrapper() { :; }
    fi

    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Downloading the file..</code>" > /dev/null

    # downloadError: Kill the script in case downloading failed
    downloadError() {
        echo "Download failed. Exiting."
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Failed to download the file.</code>" > /dev/null
        terminate 1
    }

    # Properly check for different hosting websties.
    case ${URL} in
        *drive.google.com*)
            uvx gdown@5.2.0 -q "${URL}" --fuzzy || downloadError
        ;;
        *mediafire.com*)
           uvx --from git+https://github.com/Juvenal-Yescas/mediafire-dl@5873ecf1601f1cedc10a933a3a00d340d0f02db3 mediafire-dl "${URL}" || downloadError
        ;;
        *mega.nz*)
            megatools dl "${URL}" || downloadError
        ;;
        *)
            aria2c -q -s16 -x16 --check-certificate=false "${URL}" || {
                rm -fv ./*
                wget --no-check-certificate "${URL}" || downloadError
            }
        ;;
    esac
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Downloaded the file.</code>" > /dev/null
fi

# Clean query strings if any from URL
oldifs=$IFS
IFS="?"
read -ra CLEANED <<< "${URL}"
URL=${CLEANED[0]}
IFS=$oldifs

FILE=${URL##*/}
EXTENSION=${URL##*.}
UNZIP_DIR=${FILE/.$EXTENSION/}
export UNZIP_DIR

if [[ ! -f ${FILE} ]]; then
    FILE="$(find . -type f)"
    if [[ "$(wc -l <<< "${FILE}")" != 1 ]]; then
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Can't seem to find downloaded file!</code>" > /dev/null
        terminate 1
    fi
fi

if [[ "${USE_ALT_DUMPER}" == "true" ]]; then
    sendTG_edit_wrapper temporary "${MESSAGE_ID}" "${MESSAGE}"$'\n'"Extracting firmware with Python dumpyara.." > /dev/null
    uvx dumpyara@1.0.6 "${FILE}" -o "${PWD}" || {
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extraction failed!</code>" > /dev/null
        terminate 1
    }
else
    EXTERNAL_TOOLS=(
        https://github.com/AndroidDumps/Firmware_extractor
        https://github.com/marin-m/vmlinux-to-elf
    )

    for tool_url in "${EXTERNAL_TOOLS[@]}"; do
        tool_path="${HOME}/${tool_url##*/}"
        if ! [[ -d ${tool_path} ]]; then
            git clone -q "${tool_url}" "${tool_path}"
        else
            git -C "${tool_path}" pull
        fi
    done

    sendTG_edit_wrapper temporary "${MESSAGE_ID}" "${MESSAGE}"$'\n'"Extracting firmware.." > /dev/null
    bash ~/Firmware_extractor/extractor.sh "${FILE}" "${PWD}" || {
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extraction failed!</code>" > /dev/null
        terminate 1
    }

    PARTITIONS=(system systemex system_ext system_other
        vendor cust odm odm_ext oem factory product modem
        xrom oppo_product opproduct reserve india
        my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap
        my_custom my_manifest my_carrier my_region my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm mi_ext
    )

    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extracting partitions ..</code>" > /dev/null
    # Extract the images
    for p in "${PARTITIONS[@]}"; do
        if [[ -f $p.img ]]; then
            sendTG_edit_wrapper temporary "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Partition Name: ${p}</code>" > /dev/null
            mkdir "$p" || rm -rf "${p:?}"/*

            # Try to extract images via 'fsck.erofs'
            echo "Trying to extract $p partition via fsck.erofs."
            ~/Firmware_extractor/tools/Linux/bin/fsck.erofs --extract="$p" "$p".img || {

                # Uses '7z' if images could not be extracted via 'fsck.erofs'
                echo "Extraction via fsck.erofs failed, extracting $p partition via 7z"
                7z x "$p".img -y -o"$p"/ || {

                    # Uses mount 'loop' if extraction via '7z' failed
                    rm -rf "${p}"/*
                    echo "Couldn't extract $p partition via 7z. Using mount loop"
                    mount -o loop -t auto "$p".img "$p"
                    mkdir "${p}_"
                    cp -rf "${p}/*" "${p}_"
                    umount "${p}"
                    mv "${p}_" "${p}"
                }
            }
            # Clean-up
            rm -fv "$p".img
        fi
    done
fi

rm -fv "$FILE"

# clear the last partition status
sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}" > /dev/null

# Bail out right now if no system build.prop
ls system/build*.prop 2> /dev/null || ls system/system/build*.prop 2> /dev/null || {
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>No system build*.prop found, pushing cancelled!</code>" > /dev/null
    terminate 1
}

for image in init_boot.img vendor_kernel_boot.img vendor_boot.img boot.img dtbo.img; do
    if [[ ! -f ${image} ]]; then
        x=$(find . -type f -name "${image}")
        if [[ -n $x ]]; then
            mv -v "$x" "${image}"
        else
            echo "${image} not found!"
        fi
    fi
done

# Extract kernel, device-tree blobs [...]
## Set commonly used tools
UNPACKBOOTIMG="${HOME}/Firmware_extractor/tools/Linux/bin/unpackbootimg"
KALLSYMS_FINDER="${HOME}/vmlinux-to-elf/kallsyms-finder"
VMLINUX_TO_ELF="${HOME}/vmlinux-to-elf/vmlinux-to-elf"

# Extract 'boot.img'
if [[ -f "${PWD}/boot.img" ]]; then
    # Set a variable for each path
    ## Image
    IMAGE=${PWD}/boot.img

    ## Output
    OUTPUT=${PWD}/boot

    # Create necessary directories
    mkdir -p "${OUTPUT}/dts"
    mkdir -p "${OUTPUT}/dtb"

    # Extract device-tree blobs from 'boot.img'
    extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" > /dev/null 
    rm -rf "${OUTPUT}/dtb/00_kernel"

    # Do not run 'dtc' if no DTB was found
    if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
        # Decompile '.dtb' to '.dts'
        for dtb in $(find "${PWD}/boot/dtb" -type f); do
            dtc -q -I dtb -O dts "${dtb}" >> "${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
        done
    fi

    # Extract 'ikconfig'
    if command -v extract-ikconfig > /dev/null ; then
        extract-ikconfig "${PWD}"/boot.img > "${PWD}"/ikconfig
    fi

    # Kallsyms
    python3 "${KALLSYMS_FINDER}" "${IMAGE}" > kallsyms.txt

    # ELF
    python3 "${VMLINUX_TO_ELF}" "${IMAGE}" boot.elf

    # Python rewrite automatically extracts such partitions
    if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
        mkdir -p "${OUTPUT}/ramdisk"

        # Unpack 'boot.img' through 'unpackbootimg'
        ${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}"

        # Decrompress 'boot.img-ramdisk'
        ## Run only if 'boot.img-ramdisk' is not empty
        if [[ $(file boot.img-ramdisk | grep LZ4) || $(file boot.img-ramdisk | grep gzip) ]]; then
            unlz4 "${OUTPUT}/boot.img-ramdisk" "${OUTPUT}/ramdisk.lz4"
            7z x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk"

            ## Clean-up
            rm -rf "${OUTPUT}/ramdisk.lz4"
        fi
    fi
fi

# Extract 'vendor_boot.img'
if [[ -f "${PWD}/vendor_boot.img" ]]; then
    # Set a variable for each path
    ## Image
    IMAGE=${PWD}/vendor_boot.img

    ## Output
    OUTPUT=${PWD}/vendor_boot

    # Create necessary directories
    mkdir -p "${OUTPUT}/dts"
    mkdir -p "${OUTPUT}/dtb"
    mkdir -p "${OUTPUT}/ramdisk"

    # Extract device-tree blobs from 'vendor_boot.img'
    extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" > /dev/null
    rm -rf "${OUTPUT}/dtb/00_kernel"

    # Decompile '.dtb' to '.dts'
    if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
        # Decompile '.dtb' to '.dts'
        for dtb in $(find "${OUTPUT}/dtb" -type f); do
            dtc -q -I dtb -O dts "${dtb}" >> "${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
        done
    fi

    # Python rewrite automatically extracts such partitions
    if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
        mkdir -p "${OUTPUT}/ramdisk"

        ## Unpack 'vendor_boot.img' through 'unpackbootimg'
        ${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}"

        # Decrompress 'vendor_boot.img-vendor_ramdisk'
        unlz4 "${OUTPUT}/vendor_boot.img-vendor_ramdisk" "${OUTPUT}/ramdisk.lz4"
        7z x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk"

        ## Clean-up
        rm -rf "${OUTPUT}/ramdisk.lz4"
    fi
fi

# Extract 'vendor_kernel_boot.img'
if [[ -f "${PWD}/vendor_kernel_boot.img" ]]; then
    # Set a variable for each path
    ## Image
    IMAGE=${PWD}/vendor_kernel_boot.img

    ## Output
    OUTPUT=${PWD}/vendor_kernel_boot

    # Create necessary directories
    mkdir -p "${OUTPUT}/dts"
    mkdir -p "${OUTPUT}/dtb"

    # Extract device-tree blobs from 'vendor_kernel_boot.img'
    extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" > /dev/null
    rm -rf "${OUTPUT}/dtb/00_kernel"

    # Decompile '.dtb' to '.dts'
    if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
        # Decompile '.dtb' to '.dts'
        for dtb in $(find "${OUTPUT}/dtb" -type f); do
            dtc -q -I dtb -O dts "${dtb}" >> "${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
        done
    fi

    # Python rewrite automatically extracts such partitions
    if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
        mkdir -p "${OUTPUT}/ramdisk"

        # Unpack 'vendor_kernel_boot.img' through 'unpackbootimg'
        ${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}"

        # Decrompress 'vendor_kernel_boot.img-vendor_ramdisk'
        unlz4 "${OUTPUT}/vendor_kernel_boot.img-vendor_ramdisk" "${OUTPUT}/ramdisk.lz4"
        7z x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk"

        ## Clean-up
        rm -rf "${OUTPUT}/ramdisk.lz4"
    fi
fi

# Extract 'init_boot.img'
if [[ -f "${PWD}/init_boot.img" ]]; then
    # Set a variable for each path
    ## Image
    IMAGE=${PWD}/init_boot.img

    ## Output
    OUTPUT=${PWD}/init_boot

    # Create necessary directories
    mkdir -p "${OUTPUT}/dts"
    mkdir -p "${OUTPUT}/dtb"

    # Python rewrite automatically extracts such partitions
    if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
        mkdir -p "${OUTPUT}/ramdisk"

        # Unpack 'init_boot.img' through 'unpackbootimg'
        ${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}"

        # Decrompress 'init_boot.img-ramdisk'
        unlz4 "${OUTPUT}/init_boot.img-ramdisk" "${OUTPUT}/ramdisk.lz4"
        7z x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk"

        ## Clean-up
        rm -rf "${OUTPUT}/ramdisk.lz4"
    fi
fi

# Extract 'dtbo.img'
if [[ -f "${PWD}/dtbo.img" ]]; then
    # Set a variable for each path
    ## Image
    IMAGE=${PWD}/dtbo.img

    ## Output
    OUTPUT=${PWD}/dtbo

    # Create necessary directories
    mkdir -p "${OUTPUT}/dts"

    # Extract device-tree blobs from 'dtbo.img'
    extract-dtb "${IMAGE}" -o "${OUTPUT}" > /dev/null
    rm -rf "${OUTPUT}/00_kernel"

    # Decompile '.dtb' to '.dts'
    for dtb in $(find "${OUTPUT}" -type f); do
        dtc -q -I dtb -O dts "${dtb}" >> "${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
    done
fi

# Oppo/Realme/OnePlus devices have some images in folders, extract those
for dir in "vendor/euclid" "system/system/euclid" "reserve/reserve"; do
    [[ -d ${dir} ]] && {
        pushd "${dir}" || terminate 1
        for f in *.img; do
            [[ -f $f ]] || continue
            sendTG_edit_wrapper temporary "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Partition Name: ${p}</code>" > /dev/null
            7z x "$f" -o"${f/.img/}"
            rm -fv "$f"
        done
        popd || terminate 1
    }
done

sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>All partitions extracted.</code>" > /dev/null

# board-info.txt
find ./modem -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >> ./board-info.txt
find ./tz* -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >> ./board-info.txt
if [ -f ./vendor/build.prop ]; then
    strings ./vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >> ./board-info.txt
fi
sort -u -o ./board-info.txt ./board-info.txt

# Prop extraction
sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extracting props..</code>" > /dev/null

oplus_pipeline_key=$(grep -m1 -oP "(?<=^ro.oplus.pipeline_key=).*" -hs my_manifest/build*.prop)

flavor=$(grep -m1 -oP "(?<=^ro.build.flavor=).*" -hs {vendor,system,system/system}/build.prop)
[[ -z ${flavor} ]] && flavor=$(grep -m1 -oP "(?<=^ro.vendor.build.flavor=).*" -hs vendor/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -m1 -oP "(?<=^ro.build.flavor=).*" -hs {vendor,system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -m1 -oP "(?<=^ro.system.build.flavor=).*" -hs {system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -m1 -oP "(?<=^ro.build.type=).*" -hs {system,system/system}/build*.prop)

release=$(grep -m1 -oP "(?<=^ro.build.version.release=).*" -hs {my_manifest,vendor,system,system/system}/build*.prop)
[[ -z ${release} ]] && release=$(grep -m1 -oP "(?<=^ro.vendor.build.version.release=).*" -hs vendor/build*.prop)
[[ -z ${release} ]] && release=$(grep -m1 -oP "(?<=^ro.system.build.version.release=).*" -hs {system,system/system}/build*.prop)
release=$(echo "$release" | head -1)

id=$(grep -m1 -oP "(?<=^ro.build.id=).*" -hs my_manifest/build*.prop)
[[ -z ${id} ]] && id=$(grep -m1 -oP "(?<=^ro.build.id=).*" system/system/build_default.prop)
[[ -z ${id} ]] && id=$(grep -m1 -oP "(?<=^ro.build.id=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${id} ]] && id=$(grep -m1 -oP "(?<=^ro.build.id=).*" -hs {vendor,system,system/system}/build*.prop)
[[ -z ${id} ]] && id=$(grep -m1 -oP "(?<=^ro.vendor.build.id=).*" -hs vendor/build*.prop)
[[ -z ${id} ]] && id=$(grep -m1 -oP "(?<=^ro.system.build.id=).*" -hs {system,system/system}/build*.prop)
id=$(echo "$id" | head -1)

incremental=$(grep -m1 -oP "(?<=^ro.build.version.incremental=).*" -hs my_manifest/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.build.version.incremental=).*" -hs system/system/build_default.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.build.version.incremental=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.build.version.incremental=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs my_manifest/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.system.build.version.incremental=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.system.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -m1 -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs my_product/build*.prop)
incremental=$(echo "$incremental" | head -1)

tags=$(grep -m1 -oP "(?<=^ro.build.tags=).*" -hs {vendor,system,system/system}/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -m1 -oP "(?<=^ro.vendor.build.tags=).*" -hs vendor/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -m1 -oP "(?<=^ro.system.build.tags=).*" -hs {system,system/system}/build*.prop)
tags=$(echo "$tags" | head -1)

platform=$(grep -m1 -oP "(?<=^ro.board.platform=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${platform} ]] && platform=$(grep -m1 -oP "(?<=^ro.vendor.board.platform=).*" -hs vendor/build*.prop)
[[ -z ${platform} ]] && platform=$(grep -m1 -oP rg"(?<=^ro.system.board.platform=).*" -hs {system,system/system}/build*.prop)
platform=$(echo "$platform" | head -1)

manufacturer=$(grep -oP "(?<=^ro.product.odm.manufacturer=).*" -hs odm/etc/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs odm/etc/fingerprint/build.default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.brand.sub=).*" -hs my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.brand.sub=).*" -hs system/system/euclid/my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.vendor.product.manufacturer=).*" -hs vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.system.product.manufacturer=).*" -hs {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.system.manufacturer=).*" -hs {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.odm.manufacturer=).*" -hs my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.odm.manufacturer=).*" -hs system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.odm.manufacturer=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.odm.manufacturer=).*" -hs vendor/odm/etc/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.manufacturer=).*" -hs vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.system.product.manufacturer=).*" -hs vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -m1 -oP "(?<=^ro.product.product.manufacturer=).*" -hs vendor/euclid/product/build*.prop)
manufacturer=$(echo "$manufacturer" | head -1)

fingerprint=$(grep -m1 -oP "(?<=^ro.odm.build.fingerprint=).*" -hs odm/etc/*build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs my_manifest/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs system/system/build_default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs odm/etc/fingerprint/build.default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.build.fingerprint=).*" -hs my_manifest/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.build.fingerprint=).*" -hs system/system/build_default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.build.fingerprint=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.build.fingerprint=).*" -hs  {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.product.build.fingerprint=).*" -hs product/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.system.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.system.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -m1 -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs my_product/build.prop)
fingerprint=$(echo "$fingerprint" | head -1)

codename=$(grep -m1 -oP "(?<=^ro.product.odm.device=).*" -hs odm/etc/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.odm.device=).*" -hs system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs odm/etc/fingerprint/build.default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs my_manifest/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.vendor.device=).*" -hs system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.vendor.product.device=).*" -hs system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.vendor.product.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.vendor.product.device.oem=).*" -hs odm/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.vendor.product.device.oem=).*" -hs vendor/euclid/odm/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.vendor.device=).*" -hs my_manifest/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.system.device=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.system.device=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.product.device=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.product.device=).*" -hs system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.product.model=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.device=).*" -hs {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.product.device=).*" -hs oppo_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.system.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.product.vendor.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.build.fota.version=).*" -hs {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z ${codename} ]] && codename=$(grep -m1 -oP "(?<=^ro.build.product=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)
[[ -z $codename ]] && {
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Codename not detected! Aborting!</code>" > /dev/null
    terminate 1
}

brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/${codename}_build.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs odm/etc/fingerprint/build.default.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand.sub=).*" -hs my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand.sub=).*" -hs system/system/euclid/my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.vendor.brand=).*" -hs my_manifest/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.vendor.brand=).*" -hs system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.vendor.product.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.system.brand=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${brand} || ${brand} == "OPPO" ]] && brand=$(grep -m1 -oP "(?<=^ro.product.system.brand=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.product.brand=).*" -hs vendor/euclid/product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs my_manifest/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.odm.brand=).*" -hs vendor/odm/etc/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -m1 -oP "(?<=^ro.product.brand=).*" -hs {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(echo "$fingerprint" | cut -d / -f1)

description=$(grep -m1 -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build*.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.product.build.description=).*" -hs product/build.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.product.build.description=).*" -hs product/build*.prop)
[[ -z ${description} ]] && description=$(grep -m1 -oP "(?<=^ro.system.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description="$flavor $release $id $incremental $tags"

is_ab=$(grep -m1 -oP "(?<=^ro.build.ab_update=).*" -hs {system,system/system,vendor}/build*.prop)
is_ab=$(echo "$is_ab" | head -1)
[[ -z ${is_ab} ]] && is_ab="false"

codename=$(echo "$codename" | tr ' ' '_')

if [ -z "$oplus_pipeline_key" ];then
    branch=$(echo "$description" | head -1 | tr ' ' '-')
else
    branch=$(echo "$description"--"$oplus_pipeline_key" | head -1 | tr ' ' '-')
fi

repo_subgroup=$(echo "$brand" | tr '[:upper:]' '[:lower:]')
[[ -z $repo_subgroup ]] && repo_subgroup=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')
repo_name=$(echo "$codename" | tr '[:upper:]' '[:lower:]')
repo="$repo_subgroup/$repo_name"
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)

sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>All props extracted.</code>" > /dev/null

printf "%s\n" "flavor: ${flavor}
release: ${release}
id: ${id}
incremental: ${incremental}
tags: ${tags}
oplus_pipeline_key: ${oplus_pipeline_key}
fingerprint: ${fingerprint}
brand: ${brand}
codename: ${codename}
description: ${description}
branch: ${branch}
repo: ${repo}
manufacturer: ${manufacturer}
platform: ${platform}
top_codename: ${top_codename}
is_ab: ${is_ab}"

sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Generating device tree</code>" > /dev/null
mkdir -p aosp-device-tree
if uvx aospdtgen@1.1.1 . --output ./aosp-device-tree; then
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>AOSP device tree successfully generated.</code>" > /dev/null
else
    echo "Failed to generate AOSP device tree"
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Failed to generate AOSP device tree</code>" > /dev/null
fi

# Generate all_files.txt
find . -type f -printf '%P\n' | sort | grep -v ".git/" > ./all_files.txt

# Check whether the subgroup exists or not
if ! group_id_json="$(curl --compressed -sH --fail-with-body "Authorization: Bearer $DUMPER_TOKEN" "https://$GITLAB_SERVER/api/v4/groups/$ORG%2f$repo_subgroup")"; then
    echo "Response: $group_id_json"
    if ! group_id_json="$(curl --compressed -sH --fail-with-body "Authorization: Bearer $DUMPER_TOKEN" "https://$GITLAB_SERVER/api/v4/groups" -X POST -F name="${repo_subgroup^}" -F parent_id=64 -F path="${repo_subgroup}" -F visibility=public)"; then
        echo "Creating subgroup for $repo_subgroup failed"
        echo "Response: $group_id_json"
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Creating subgroup for $repo_subgroup failed!</code>" > /dev/null
    fi
fi

if ! group_id="$(jq '.id' -e <<< "${group_id_json}")"; then
    echo "Unable to get gitlab group id"
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Unable to get gitlab group id!</code>" > /dev/null
    terminate 1
fi

# Create the repo if it doesn't exist
project_id_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$ORG%2f$repo_subgroup%2f$repo_name")"
if ! project_id="$(jq .id -e <<< "${project_id_json}")"; then
    project_id_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects" -X POST -F namespace_id="$group_id" -F name="$repo_name" -F visibility=public)"
    if ! project_id="$(jq .id -e <<< "${project_id_json}")"; then
        echo "Could get get project id"
        sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Could not get project id!</code>" > /dev/null
        terminate 1
    fi
fi

branch_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$project_id/repository/branches/$branch")"
[[ "$(jq -r '.name' -e <<< "${branch_json}")" == "$branch" ]] && {
    echo "$branch already exists in $repo"
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>$branch already exists in</code> <a href=\"https://$GITLAB_SERVER/$ORG/$repo/tree/$branch/\">$repo</a>!" > /dev/null
    terminate 0
}

# Add, commit, and push after filtering out certain files
git init --initial-branch "$branch"
git config user.name "dumper"
git config user.email "dumper@$GITLAB_SERVER"
# find . -size +97M -printf '%P\n' -o -name '*sensetime*' -printf '%P\n' -o -iname '*Megvii*' -printf '%P\n' -o -name '*.lic' -printf '%P\n' -o -name '*zookhrs*' -printf '%P\n' > .gitignore
sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Committing..</code>" > /dev/null
git add -A
git commit --quiet --signoff --message="$description"

sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushing..</code>" > /dev/null
git push "$PUSH_HOST:$ORG/$repo.git" HEAD:refs/heads/"$branch" || {
    sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushing failed!</code>" > /dev/null
    echo "Pushing failed!"
    terminate 1
}

# Set default branch to the newly pushed branch
curl --compressed -s -H "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$project_id" -X PUT -F default_branch="$branch" > /dev/null

# Send message to Telegram group
sendTG_edit_wrapper permanent "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushed</code> <a href=\"https://$GITLAB_SERVER/$ORG/$repo/tree/$branch/\">$description</a>" > /dev/null

# Prepare message to be sent to Telegram channel
commit_head=$(git rev-parse HEAD)
commit_link="https://$GITLAB_SERVER/$ORG/$repo/commit/$commit_head"
echo -e "Sending telegram notification"
tg_html_text="<b>Brand: $brand</b>
<b>Device: $codename</b>
<b>Version: $release</b>
<b>Fingerprint: $fingerprint</b>
<b>Platform: $platform</b>
<b>Git link:</b>
<a href=\"$commit_link\">Commit</a>
<a href=\"https://$GITLAB_SERVER/$ORG/$repo/tree/$branch/\">$codename</a>"

# Send message to Telegram channel
curl --compressed -s "https://api.telegram.org/bot${API_KEY}/sendmessage" --data "text=${tg_html_text}&chat_id=@android_dumps&parse_mode=HTML&disable_web_page_preview=True" > /dev/null

terminate 0
