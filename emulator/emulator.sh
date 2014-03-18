#!/bin/bash

echo "ERROR: the emulator.sh script needs to be changed to support your emulator!"
exit 1


###
### Example for the aarch64 emulator:
###

LOG=$(mktemp)
./Foundation_v8 --image ./img-foundation.axf \
                 --block-device "$1" \
                 --network=none &> $LOG &
while test 0$(grep -c terminal_0: $LOG ) -lt 1; do
    echo ".."
    sleep 1
done
cat $LOG
# terminal_0: Listening for serial connection on port 5012
PORT=$(grep terminal_0: $LOG | head -n 1 | cut -d " " -f 8)
rm -f $LOG
# telnet dies when emulator is quiting
telnet 127.0.0.1 $PORT || exit 0


