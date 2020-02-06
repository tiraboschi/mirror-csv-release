#!/bin/bash -e


usage () {
    echo "
Usage:

${0##*/} [options] SOURCE_BUNDLE_REGISTRY DEST_PREFIX

Mirror container images listed in an operator bundle.

Positional arguments:
    SOURCE_BUNDLE_REGISTRY
        Will be used for:
          - Extract bundle files
          - Get the list of images listed in the bundle
          - Replacement string when replace the source registry and namespace
            with the destination registry and namespace.

        [e.g quay.io/openshift-cnv/container-native-virtualization-hco-bundle-registry:v2.2.0-181]

    DEST_PREFIX
       Will replace the PREFIX in the pull URL of the images that were found
       in the csv files.

       [e.g quay.io/tiraboschi/]

Optional arguments:
    -s,--dest-secret USERNAME[:PASSWORD]
        for accessing the destination registry

    --version-filter
        to mirror just a specific version

    -d,--debug
        run in debug mode

    --dry-run
        dry-run mode

Example:
    ${0##*/}  --version-filter 2.2.0 quay.io/openshift-cnv/container-native-virtualization-hco-bundle-registry:v2.2.0-181  quay.io/tiraboschi/

"
}

function cleanup()
{
    rm -rf ${tmp_dir}
}


tmp_dir=$(mktemp -d -t mr-XXXXXXXXXX)
trap cleanup EXIT

main() {
    local csv_files
    local source_images=()
    local dest_secret=""
    local version_filter=""
    local options

    options=$( \
        getopt \
            -o hs:p:d \
            --long help,version-filter:,dest-secret:,debug,dry-run \
            -n "$0" \
            -- "$@" \
    )
    if [[ "$?" != "0" ]]; then
        echo "Failed to parse cmd arguments" >&2
        exit 1
    fi
    eval set -- "$options"

    while true; do
        case $1 in
            -s|--dest-secret)
                dest_secret="$2"
                shift 2
                ;;
            --version-filter)
                version_filter="$2"
                shift 2
                ;;
            -d|--debug)
                set -x
                shift 1
                ;;
            --dry-run)
                DRY_RUN=true
                shift 1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
        esac
    done

    # Positional arguments
    local bundle_image="${1:?usage SOURCE_BUNDLE_REGISTRY was not specified}"
    local dest_prefix="${2:?usage DEST_PREFIX was not specified}"

    get_bundle_content "$bundle_image"
    csv_files=($(get_csv_files $version_filter))
    source_images=($(get_source_images "${csv_files[@]}"))

    mirror "$dest_prefix" "$dest_secret" "${source_images[@]}"
    build_and_publish_patched_bundle_image "$bundle_image" "$dest_prefix"
}


get_bundle_content() {
    local bundle_image="${1:?}"
    container_id=$(podman create $bundle_image)
    podman cp ${container_id}:/manifests ${tmp_dir}
    podman rm ${container_id}
}


get_csv_files() {
    local version_filter="${1}"
    find ${tmp_dir}/manifests -type f -name "*${version_filter}.clusterserviceversion.yaml"
}


get_source_images() {
    local source_images=()
    for csv in "$@"; do
        source_images+=$(cat "${csv}"  | python3 -c 'import yaml,sys;obj=yaml.safe_load(sys.stdin);print("\n".join([x["image"] for x in obj["spec"]["relatedImages"]]))' )
    done
    # Remove duplicate images
    printf '%s\n' "${source_images[@]}" | sort -u
}


get_dest_image() {
    local source_image="${1:?}"
    local dest_prefix="${2:?}"
    local source_registry=${source_image%\/*}/
    local image_name_tag=${source_image:${#source_registry}}
    # workaround for https://bugzilla.redhat.com/1794040
    local image_name_tag_nosha=${image_name_tag/@sha256/}
    echo "${dest_prefix}${image_name_tag_nosha}"
}

mirror() {
    # This expension is safe sense an image name can't have whitespaces
    local dest_prefix="${1:?}"
    shift
    local dest_secret="${1}"
    shift
    local source_images=("$@")
    local dry_run
    local dest_image
    local all

    [[ "$DRY_RUN" ]] && dry_run=echo
    [[ "$dest_secret" ]] && dest_secret="--dest-creds $dest_secret"

    for source_image in "$@"; do
        all=""
        if [[ ${source_image} == *"@sha256"* ]]; then
          all="--all"
        fi
        dest_image=$(get_dest_image "${source_image}" "${dest_prefix}")
        echo -e "\e[41mMirroring ${source_image} -> ${dest_image}\e[49m"
        bash -c "$dry_run skopeo copy $all $dest_secret docker://${source_image} docker://${dest_image}"
    done

}

build_and_publish_patched_bundle_image() {
    local bundle_image="${1:?}"
    local dest_prefix="${2:?}"
    local source_registry=${source_image%\/*}/
    local dest_image=$(get_dest_image "${bundle_image}" "${dest_prefix}")
    local dry_run
    [[ "$DRY_RUN" ]] && dry_run=echo

    cp Dockerfile ${tmp_dir}
    echo -e "\e[41mRecreating bundle registry image\e[49m"
    podman build --build-arg PARENT_IMAGE="${bundle_image}" \
       --build-arg SOURCE="${source_registry}" \
       --build-arg DESTINATION="${dest_prefix}"  ${tmp_dir} -t "${dest_image}"
    bash -c "$dry_run podman push ${dest_image}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
else
    # Don't fail if somone try to source this script
    :
fi
