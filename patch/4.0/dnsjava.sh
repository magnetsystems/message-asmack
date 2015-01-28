#!/bin/bash

echo $PWD
cp -r ../../src/smack/mmx-smack-resolver-dnsjava/src/main/java/ .
rm -rf org/jivesoftware/smack/util/dns/minidns
