#!/bin/bash

################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

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


