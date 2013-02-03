#!/bin/bash

echo "ERROR: the emulator.sh script got not changed to support your emulator!"
exit 1


###
### Example for the aarch64 emulator:
###

#LOG=/tmp/foundation.$$

#./Foundation_v8 --image img-foundation.axf \
#                 --block-device "$1" \
#                 --network=none &> $LOG &
#sleep 3

# terminal_0: Listening for serial connection on port 5012
#PORT=$(head -n 1 $LOG | cut -d " " -f 8)
#rm -f $LOG
#telnet localhost $PORT || exit 0


