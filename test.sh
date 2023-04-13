#!/bin/sh
# [[file:README.org::*Main section][Main section:2]]
#!/usr/bin/env sh
set -e
set -u
echo "info" "test.sh started"
export VVC_REPOSITORY="test-repository"

BASEDIR=$(dirname "$0")
cd "$BASEDIR" || exit

# test adding variants
TEST_VARIANTS="18:36156575:G:A 18:36156575:G:T 18:36156575:G:C 18:36156575:G:AT 18:36156575:G:AC chr12:48968150:T:C chr12:48968150:T:G chr16:3254555:C:T chr16:3254555:C:G"
echo "info" "test.sh adding variants"
./vvc.sh add $TEST_VARIANTS
# for variant in $TEST_VARIANTS; do
#     ./vvc.sh add "$variant"
# done

# test updating variants
echo "info" "test.sh updating variants"
./vvc.sh update

# test listing variants
echo "info" "test.sh listing variants"
./vvc.sh list
# Main section:2 ends here
