#!/usr/bin/env bash

[[ -z ${API_KEY} ]] && echo "API_KEY not defined, exiting!" && exit 1

function sendTG() {
    curl -s "https://api.telegram.org/bot${API_KEY}/sendmessage" --data "text=${*}&chat_id=-1001412293127&parse_mode=HTML" > /dev/null
}

[[ -z $ORG ]] && ORG="dumps"

if [[ -f $URL ]]; then
    cp -v "$URL" .
    sendTG "Found file locally"
else
    sendTG "Starting <a href=\"${URL}\">dump</a> on <a href=\"$BUILD_URL\">jenkins</a>"
    if [[ $URL =~ drive.google.com ]]; then
        FILE_ID="$(echo "${URL:?}" | sed -r 's/.*([0-9a-zA-Z_-]{33}).*/\1/')"
        CONFIRM=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate "https://docs.google.com/uc?export=download&id=$FILE_ID" -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')
        aria2c --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$CONFIRM&id=$FILE_ID" || exit 1
        rm /tmp/cookies.txt
    elif [[ $URL =~ mega.nz ]]; then
        megadl "'$URL'" || exit 1
    else
        # Try to download certain URLs with axel first
        if [[ $URL =~ ^.+(ota\.d\.miui\.com|otafsg|oxygenos\.oneplus\.net|dl.google|android.googleapis|ozip)(.+)?$ ]]; then
            axel -q -a -n64 "$URL" || {
                # Try to download with aria, else wget. Clean the directory each time.
                aria2c -j64 "${URL}" || {
                    rm -fv ./*
                    wget "${URL}" || {
                        echo "Download failed. Exiting."
                        sendTG "Failed to download the file."
                        exit 1
                    }
                }
            }
        else
            # Try to download with aria, else wget. Clean the directory each time.
            aria2c -j64 "${URL}" || {
                rm -fv ./*
                wget "${URL}" || {
                    echo "Download failed. Exiting."
                    sendTG "Failed to download the file."
                    exit 1
                }
            }
        fi
    fi
    sendTG "Downloaded the file"
fi

FILE=${URL##*/}
EXTENSION=${URL##*.}
UNZIP_DIR=${FILE/.$EXTENSION/}
export UNZIP_DIR

if [[ ! -f ${FILE} ]]; then
    if [[ "$(find . -type f | wc -l)" != 1 ]]; then
        sendTG "Can't seem to find downloaded file!"
        exit 1
    else
        FILE="$(find . -type f)"
    fi
fi

PARTITIONS="system vendor cust odm oem factory product modem xrom systemex system_ext system_other oppo_product opproduct reserve india my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap"

if [[ ! -d "${HOME}/extract-dtb" ]]; then
    git clone -q https://github.com/PabloCastellano/extract-dtb ~/extract-dtb
else
    git -C ~/extract-dtb pull
fi

if [[ ! -d "${HOME}/Firmware_extractor" ]]; then
    git clone -q https://github.com/AndroidDumps/Firmware_extractor ~/Firmware_extractor
else
    git -C ~/Firmware_extractor pull
fi

if [[ ! -d "${HOME}/mkbootimg_tools" ]]; then
    git clone -q https://github.com/xiaolu/mkbootimg_tools ~/mkbootimg_tools
else
    git -C ~/mkbootimg_tools pull
fi

bash ~/Firmware_extractor/extractor.sh "${FILE}" "${PWD}" || (
    sendTG "Extraction failed!"
    exit 1
)

rm -fv "$FILE"

# Extract the images
for p in $PARTITIONS; do
    if [ -f "$p.img" ]; then
        mkdir "$p" || rm -rf "${p:?}"/*
        7z x "$p".img -y -o"$p"/ || {
        sudo mount -o loop "$p".img "$p"
        mkdir "${p}_"
        sudo cp -rf "${p}/*" "${p}_"
        sudo umount "${p}"
        sudo mv "${p}_" "${p}"
}
        rm -fv "$p".img
    fi
done

# Bail out right now if no system build.prop
ls system/build*.prop 2> /dev/null || ls system/system/build*.prop 2> /dev/null || {
    sendTG "No system build*.prop found, pushing cancelled!"
    exit 1
}

# Extract bootimage and dtbo
if [[ -f "boot.img" ]]; then
    mkdir -v bootdts
    ~/mkbootimg_tools/mkboot ./boot.img ./bootimg > /dev/null
    python3 ~/extract-dtb/extract-dtb.py ./boot.img -o ./bootimg > /dev/null
    find bootimg/ -name '*.dtb' -type f -exec dtc -I dtb -O dts {} -o bootdts/"$(echo {} | sed 's/\.dtb/.dts/')" \; > /dev/null 2>&1
    rm -fv boot.img
fi
if [[ -f "dtbo.img" ]]; then
    mkdir -v dtbodts 
    python3 ~/extract-dtb/extract-dtb.py ./dtbo.img -o ./dtbo > /dev/null
    find dtbo/ -name '*.dtb' -type f -exec dtc -I dtb -O dts {} -o dtbodts/"$(echo {} | sed 's/\.dtb/.dts/')" \; > /dev/null 2>&1
fi

# Oppo/Realme devices have some images in a euclid folder in their vendor, extract those for props
if [[ -d "vendor/euclid" ]]; then
    pushd vendor/euclid || exit 1
    for f in *.img; do
        [[ -f "$f" ]] || continue
        7z x "$f" -o"${f/.img/}"
        rm -fv "$f"
    done
    popd || exit 1
fi

# board-info.txt
find ./modem -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >> ./board-info.txt
find ./tz* -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >> ./board-info.txt
if [ -f ./vendor/build.prop ]; then
    strings ./vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >> ./board-info.txt
fi
sort -u -o ./board-info.txt ./board-info.txt

# Fix permissions
sudo chown "$(whoami)" ./* -R
sudo chmod -R u+rwX ./*

# Generate all_files.txt
find . -type f -printf '%P\n' | sort | grep -v ".git/" > ./all_files.txt

# Prop extraction
flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.vendor.build.flavor=).*" -hs vendor/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.system.build.flavor=).*" -hs {system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.build.type=).*" -hs {system,system/system}/build*.prop)
release=$(grep -oP "(?<=^ro.build.version.release=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${release} ]] && release=$(grep -oP "(?<=^ro.vendor.build.version.release=).*" -hs vendor/build*.prop)
[[ -z ${release} ]] && release=$(grep -oP "(?<=^ro.system.build.version.release=).*" -hs {system,system/system}/build*.prop)
id=$(grep -oP "(?<=^ro.build.id=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${id} ]] && id=$(grep -oP "(?<=^ro.vendor.build.id=).*" -hs vendor/build*.prop)
[[ -z ${id} ]] && id=$(grep -oP "(?<=^ro.system.build.id=).*" -hs {system,system/system}/build*.prop)
incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs {system,system/system}/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs my_product/build*.prop)
tags=$(grep -oP "(?<=^ro.build.tags=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -oP "(?<=^ro.vendor.build.tags=).*" -hs vendor/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -oP "(?<=^ro.system.build.tags=).*" -hs {system,system/system}/build*.prop)
platform=$(grep -oP "(?<=^ro.board.platform=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${platform} ]] && platform=$(grep -oP "(?<=^ro.vendor.board.platform=).*" -hs vendor/build*.prop)
[[ -z ${platform} ]] && platform=$(grep -oP rg"(?<=^ro.system.board.platform=).*" -hs {system,system/system}/build*.prop)
manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.vendor.product.manufacturer=).*" -hs vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs oppo_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs my_product/build*.prop)
fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system}/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.product.build.fingerprint=).*" -hs product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.product.build.fingerprint=).*" -hs product/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs my_product/build.prop)
brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.vendor.product.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${brand} || ${brand} == "OPPO" ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs vendor/odm/etc/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs oppo_product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(echo "$fingerprint" | cut -d / -f1)
codename=$(grep -oP "(?<=^ro.product.device=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.vendor.product.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs oppo_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.build.fota.version=).*" -hs {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z ${codename} ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)
description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.product.build.description=).*" -hs product/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.product.build.description=).*" -hs product/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.system.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description="$flavor $release $id $incremental $tags"
branch=$(echo "$description" | tr ' ' '-')
repo_subgroup=$(echo "$brand" | tr '[:upper:]' '[:lower:]')
[[ -z "$repo_subgroup" ]] && repo_subgroup=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')
repo_name=$(echo "$codename" | tr '[:upper:]' '[:lower:]')
repo="$repo_subgroup/$repo_name"
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)

printf "\nflavor: %s\nrelease: %s\nid: %s\nincremental: %s\ntags: %s\nfingerprint: %s\nbrand: %s\ncodename: %s\ndescription: %s\nbranch: %s\nrepo: %s\nmanufacturer: %s\nplatform: %s\ntop_codename: %s\n" "$flavor" "$release" "$id" "$incremental" "$tags" "$fingerprint" "$brand" "$codename" "$description" "$branch" "$repo" "$manufacturer" "$platform" "$top_codename"

# Check whether this has already been dumped or not
curl --silent --fail "https://git.rip/$ORG/$repo/-/blob/$branch/all_files.txt" > /dev/null && {
    echo "Already dumped"
    sendTG "Already dumped"
    exit 1
}

# Check whether the subgroup exists or not
if ! curl -s -H "Authorization: Bearer $DUMPER_TOKEN" "https://git.rip/api/v4/groups/$ORG%2f$repo_subgroup" -s --fail > x; then
    if ! curl -H "Authorization: Bearer $DUMPER_TOKEN" "https://git.rip/api/v4/groups" -X POST -F name="${repo_subgroup^}" -F parent_id=562 -F path="${repo_subgroup}" --silent --fail > x; then
        sendTG "Creating subgroup for $repo_subgroup failed!"
        exit 1
    fi
fi
group_id="$(jq -r '.id' x)"
rm -f x

[[ -z "$group_id" ]] && {
    sendTG "Unable to get gitlab group id!"
    exit 1
}

# Create the repo if it doesn't exist
curl --silent -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects%2f$ORG%2f$repo_subgroup%2f%repo_name" > x
project_id="$(jq .id x)"
rm -f x
if [[ -z "$project_id" ]]; then
    curl --silent -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects" -X POST -F namespace_id="$group_id" -F name="$repo" -F visibility=public > x
    project_id="$(jq .id x)"
    rm -f x
    if [[ -z "$project_id" ]]; then
        sendTG "Could not get project id"
        exit 1
    fi
fi

# Add, commit, and push after filtering out certain files
git init
git config user.name 'dumper'
git config user.email '457-dumper@users.noreply.git.rip'
git checkout -b "$branch"
find . -size +97M -printf '%P\n' -o -name '*sensetime*' -printf '%P\n' -o -iname '*Megvii*' -printf '%P\n' -o -name '*.lic' -printf '%P\n' -o -name '*zookhrs*' -printf '%P\n' > .gitignore
find . -maxdepth 1 -type f -exec git add {} \;
sendTG "Committing and pushing"
git add -A
git commit --quiet --signoff --message="$description"
git push "https://dumper:$DUMPER_TOKEN@git.rip/$ORG/$repo.git" HEAD:refs/heads/"$branch"
   
# Set default branch to the newly pushed branch
curl -s -X PATCH -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects/$project_id" -X PUT -F default_branch="$branch" > /dev/null

# Send message to Telegram group
sendTG "Pushed <a href=\"https://git.rip/$ORG/$repo\">$description</a>"

# Prepare message to be sent to Telegram channel
commit_head=$(git rev-parse HEAD)
commit_link="https://git.rip/$ORG/$repo/commit/$commit_head"
echo -e "Sending telegram notification"
(
    printf "<b>Brand: %s</b>" "$brand"
    printf "\n<b>Device: %s</b>" "$codename"
    printf "\n<b>Version:</b> %s" "$release"
    printf "\n<b>Fingerprint:</b> %s" "$fingerprint"
    printf "\n<b>GitHub:</b>"
    printf "\n<a href=\"%s\">Commit</a>" "$commit_link"
    printf "\n<a href=\"https://git.rip/%s/%s/tree/%s/\">$codename</a>" "$ORG" "$repo" "$branch"
) >> tg.html

TEXT=$(cat tg.html)

# Send message to Telegram channel
curl -s "https://api.telegram.org/bot${API_KEY}/sendmessage" --data "text=${TEXT}&chat_id=@android_dumps&parse_mode=HTML&disable_web_page_preview=True" > /dev/null

# Delete file after sending message
rm -fv tg.html
