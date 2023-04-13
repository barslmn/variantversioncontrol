#!/bin/sh
# VVC main script
# This section sets up the environment variables. These variables are:
# - VVC_DIR: directory where the variant repository is stored. Example: $HOME/.local/share
# - VVC_REPOSITORY: name of the variant repository. Example: my_variants
# - VVC_LOGLVL: log level of the script options are: DEBUG, INFO, WARNING, ERROR


# [[file:README.org::*VVC main script][VVC main script:1]]
set -e
set -u
BASEDIR=$(dirname "$0")
cd "$BASEDIR" || exit

if [ -z "${VVC_DIR-}" ]; then
    VVC_DIR="$HOME/.local/share"
fi

if [ -z "${VVC_LOGLVL-}" ]; then
    VVC_LOGLVL="INFO"
fi
if [ -z "${VVC_REPOSITORY-}" ]; then
    VVC_REPOSITORY="my_variants"
fi

. ./logger.sh
TMPDIR=$(mktemp -d VVCp$$.XXXXXX -p /tmp)
log "debug" "TEMP DIRECTORY set to: $TMPDIR"
LC_ALL=C

VARIANT_REPOSITORY="$VVC_DIR/$VVC_REPOSITORY"
CURRENT_DIR="$PWD"
readonly VERSION="0.0.1"
# VVC main script:1 ends here

# Help function
# Avaliable commands are:
# - update: update the variant repository.
#   + example usage: vvc update
# - add: add a variant to the repository
#   + example usage: vvc add rs1234
# - remove: remove a variant from the repository
#   + example usage: vvc remove rs1234
# - search: search for a variant in the repository
#   + example usage: vvc search rs1234
# - show: show information about a variant
#   + example usage: vvc show rs1234
# - list: list all variants in the repository
#   + example usage: vvc list
# - tsvlist: list all variants in the repository in tsv format
#   + example usage: vvc tsvlist
# - help: show this help
# - version: show the version of vvc


# [[file:README.org::*Help function][Help function:1]]
usage() {
    cat <<HELP
Usage
vvc { update | add | remove | show | list | tsvlist | version }
vvc provides a high-level commandline interface for the keeping track of
variant annotation changes from sources like Ensembl, NCBI via their API's.

update
    update is used to resynchronize the variant annotations from their sources.
add
    add is followed by one variant identifier (rs number, SPDI, hgvs) desired to be annotated and keep track of
remove
    remove is identical to add except that variants are removed and no longer kept track of.
search
    search for the given regex(7) term(s) from the list of track variants and display matches.
show
    show information about the given variant including its install source and update mechanism.
history
    show change history of the given variant.
list
    list the variants.
tsvlist
    tsv formatted list the variants
help
    show this help
version
    show vvc version
HELP
}
# Help function:1 ends here

# Check variant repository
# This is the first thing that is done when the script is run. The function checks
# if the variant repository exists. If it does not exist, it creates it. If it
# does exist, it changes the current directory to the variant repository.


# [[file:README.org::*Check variant repository][Check variant repository:1]]
check_variant_repository() {
    if [ -d "$VARIANT_REPOSITORY" ]; then
        log "debug" "Directory $VARIANT_REPOSITORY exists. Changing directory."
        cd "$VARIANT_REPOSITORY" || exit
        if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" ]; then
            log "debug" "Variant repository at $VARIANT_REPOSITORY exists."
            return 0
        else
            log "info" "Variant repository at $VARIANT_REPOSITORY does not exist. Creating it for you."
            git init
            touch "$VARIANT_REPOSITORY/variants"
            mkdir -p "$VARIANT_REPOSITORY/annotations"
            git add variants annotations/
            git config --add --local user.name variantversioncontrol
            git config --add --local user.email variant@version.control
            git commit -m "Initial commit"
        fi
    else
        log "info" "Directory $VARIANT_REPOSITORY does not exist. Creating it for you."
        mkdir -p "$VARIANT_REPOSITORY/annotations"
        check_variant_repository
    fi
}
# Check variant repository:1 ends here

# Validate variant
# Currently only SPDI format is supported.
# TODO: add support for rs numbers and hgvs


# [[file:README.org::*Validate variant][Validate variant:1]]
validate_variant() {
    VARIANT="$1"
    if echo "$VARIANT" | grep -P '(chr|)([1-9]|1[1-9]|2[0-2]|X|Y):(\d+):(A|T|C|G)+:(A|T|C|G)+' >/dev/null; then
        log "debug" "$VARIANT variant passed the regex validation."
    else
        log "error" "$VARIANT variant needs to be in SPDI format."
    fi
}
# Validate variant:1 ends here




# + update variant

# | step | using   | description                                     |
# |------+---------+-------------------------------------------------|
# |    1 | ENSEMBL | First run ensembl recoder.                      |
# |    2 | ENSEMBL | Get VEP annotation                              |
# |    3 | JQ      | Get HGVSg and refseq SPDI from ensembl/recoder. |
# |    4 | NCBI    | Get rsid from ncbi/variation using that HGVSg   |
# |    5 | NCBI    | Get frequencies from alfa usind rsid.           |
# |    6 | NCBI    | Get pmids from litvar using rsid.               |



# [[file:README.org::*Validate variant][Validate variant:3]]
# $1 path
# $2 data
write_data() {
    mkdir -p "annotations/$1"
    echo "$2" | jq -S '.' >"annotations/$1/data"
}

api_call() {
    url="$1"
    response_content="$2"
    method="GET"
    header="accept: application/json"
    log "debug" "function: api_call0 starting with url: $url and response_content: $response_content"
    response_code=$(curl --fail --silent --write-out "%{http_code}\n" --output "$response_content" --request "$method" --header "$header" "$url")
    log "debug" "function: api_call1 url: $url response_code: ${response_code-}"
    echo "$response_code"
}

update_variant() {
    identifiers="spdi=$1"
    sed '/^$/d;/^#/d;' "$CURRENT_DIR"/apitable.tsv | while IFS= read -r line; do
        url_tmp=$(mktemp -p "$TMPDIR")
        unset api
        unset url
        unset handler
        unset rate_limit
        log "debug" "Identifiers are: $(echo "$identifiers" | tr '\n' ' ')"
        log "debug" "url_tmp is: $url_tmp"
        api=$(echo "$line" | awk -F"\t" '{print $1}')
        url=$(echo "$line" | awk -F"\t" '{print $2}')
        handler=$(echo "$line" | awk -F"\t" '{print $3}')
        rate_limit=$(echo "$line" | awk -F"\t" '{print $4}')
        response_content=$(mktemp -p "$TMPDIR")
        printf '%s\nurl="%s"' "$identifiers" "$url" >"$url_tmp"

        # first check if the required identifiers are set
        if (. "$url_tmp" 2>/dev/null); then
            . "$url_tmp";
        else
            log "info" "Required identifiers were not set. Skipping $api.";
            continue;
        fi

        log "debug" "Calling $url"
        if [ -n "$rate_limit" ]; then
            log "debug" "Waiting for $rate_limit seconds before calling $url"
            sleep "$rate_limit"
        fi
        # log "debug" "function: update_variant0 api: $api url: $url handler: $handler rate_limit: $rate_limit response_content: $response_content"
        # response_code=$(api_call "$url" "$response_content")
        method="GET"
        header="accept: application/json"
        log "debug" "api_call starting with url: $url and response_content: $response_content"
        # TODO: insecure is required for spliceai.
        response_code=$(curl --insecure --silent --write-out "%{http_code}\n" --output "$response_content" --request "$method" --header "$header" "$url")
        log "debug" "api_call ended for $api response_code: ${response_code-}"

        log "debug" "function: update_variant1 response_code: $response_code"

        if [ "${response_code-}" -eq 200 ]; then
            response_content=$(cat "$response_content")
            if [ -n "$handler" ]; then
                log "debug" "running handler: $handler"
                identifiers=$(sh "$CURRENT_DIR/$handler" "$response_content" | sed -e 's/=\([^"][^ ]*\)/="\1"/g')
                export identifiers
            fi
            write_data "$1/$api" "$response_content"
        else
            log "info" "Call to $api returned $response_code not updating this file."
        fi
    done
    log "debug" "committing changes"
    git add .
    # pipe to true to avoid failing if there are no changes.
    git commit -m "updated $variant" || true
}
# Validate variant:3 ends here

# [[file:README.org::*Validate variant][Validate variant:4]]
update_annotations() {
    log "info" "Updating all variants."
    sed '/^$/d;/^#/d;' variants | while IFS= read -r variant; do
        log "info" "Updating variant $variant"
        update_variant "$variant"
        log "info" "Finished updating variant $variant"
    done
}
# Validate variant:4 ends here



# add variant


# [[file:README.org::*Validate variant][Validate variant:5]]
add_variant() {
    variant="$1"
    if grep "$variant" variants >/dev/null; then
        log "info" "variant $variant already added! Skipping."
        return 0
    fi
    validate_variant "$variant"

    log "info" "Adding variant $variant"
    echo "$variant" >>variants
    mkdir -p "annotations/$variant/"
    git add variants "annotations/$variant/"
    git commit -m "added variant $variant"
    update_variant "$variant"
}
# Validate variant:5 ends here

# Main section


# [[file:README.org::*Main section][Main section:1]]
main() {
    check_variant_repository
    before_hash=$(git rev-parse --short HEAD)

    if [ -n "${1}" ]; then
        ACTION="$1"
        shift
    else
        log "error" "You must specify an action."
        # usage
        exit 1
    fi

    case ${ACTION} in
        add | remove | show)
            if [ -z "${1}" ]; then
                log "error" "You must specify a variant:\n"
                list_variants
                exit 1
            fi
            ;;
    esac

    case "${ACTION}" in
        show) ;;
        add)
            for variant in "$@"; do
                add_variant "$variant"
            done
            ;;
        list)
            list_variants
            ;;
        tsv_list | tsvlist | tsv)
            tsvlist_variants
            ;;
        remove) ;;

        search)
            list_variants | grep "${1}"
            ;;
        update)
            update_annotations
            ;;
        version) echo "${VERSION}" ;;
        help) usage ;;
        *) log "fatal" "Unknown action supplied: ${ACTION}" ;;
    esac

    # TODO: maybe do the updates async?
    # while ps $! >/dev/null; do
    #     sleep 5
    #     log "info" "Processing..."
    # done

    after_hash=$(git rev-parse --short HEAD)

    if [ "$before_hash" != "$after_hash" ]; then
        log "info" "Changes were made."
        git diff --stat "$before_hash" "$after_hash"
    fi

    cd "$CURRENT_DIR" || exit
    # if [ "$LOGLVL" = 0 ]; then set +xv; fi
    if [ "$LOGLVL" -ge 1 ]; then rm -rf "$TMPDIR"; fi
}

main "$@"
# Main section:1 ends here
