#!/bin/bash
#
# Compare two branches and generate the patch file
#

skipPath() {
  awk -v str="$1" -v start=$2 'BEGIN {
          path="";
          split(str, comp, "/");
          for ( i in comp ) {
            if (i == start) {
              path = comp[i];
            } else if (i > start) {
              path = path "/" comp[i];
            }
          }
          print path;
       }'
}

getDir() {
  awk -v str="$1" -v end=$2 'BEGIN {
          path="";
          split(str, comp, "/");
          for ( i in comp ) {
            if (i == 1) {
              path = comp[i];
            } else if (i <= end) {
              path = path "/" comp[i];
            }
          }
          print path;
       }'
}

# The original 4.0.6 smack
SMACK_BRANCH=4.0.6
# The modified 4.0.6 smack with Magnet changes
MAGNET_BRANCH=4.0.6-magnet
# The patch file to be generated
PATCH_FILE=42-magnet-enhancements.patch

test -d patch-stage && rm -rf patch-stage
mkdir -p patch-stage/${SMACK_BRANCH}
mkdir -p patch-stage/${MAGNET_BRANCH}
rm -f magnet/${PATCH_FILE}

cd src/smack
# git show --pretty="format:" --name-only
for i in `git diff-tree -r $SMACK_BRANCH $MAGNET_BRANCH --name-only`; do
#  dir=`getDir $i 4`
  file=`skipPath $i 5`
  filedir=`dirname $file`
  filename=`basename $file`
  mkdir -p ../../patch-stage/${MAGNET_BRANCH}/${filedir}
  mkdir -p ../../patch-stage/${SMACK_BRANCH}/${filedir}
  git show ${MAGNET_BRANCH}:$i > ../../patch-stage/${MAGNET_BRANCH}/${file}
  git show ${SMACK_BRANCH}:$i > ../../patch-stage/${SMACK_BRANCH}/${file}
  (
    cd ../../patch-stage/${MAGNET_BRANCH}
    diff -ur ../${SMACK_BRANCH}/${file} ${file} >> ../../magnet/${PATCH_FILE}
  )
done
test -d patch-stage && rm -rf patch-stage
