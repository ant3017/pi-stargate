antonio@stargate:~/projects/pi-stargate $ sudo systemctl restart hostapd
Job for hostapd.service failed because the control process exited with error code.
See "systemctl status hostapd.service" and "journalctl -xeu hostapd.service" for details.
antonio@stargate:~/projects/pi-stargate $ journalctl -xeu hostapd.service
Nov 18 12:04:30 stargate hostapd[29319]:          <configuration file(s)>
Nov 18 12:04:30 stargate hostapd[29319]: options:
Nov 18 12:04:30 stargate hostapd[29319]:    -h   show this usage
Nov 18 12:04:30 stargate hostapd[29319]:    -d   show more debug messages (-dd for even more)
Nov 18 12:04:30 stargate hostapd[29319]:    -B   run daemon in the background
Nov 18 12:04:30 stargate hostapd[29319]:    -e   entropy file
Nov 18 12:04:30 stargate hostapd[29319]:    -g   global control interface path
Nov 18 12:04:30 stargate hostapd[29319]:    -G   group for control interfaces
Nov 18 12:04:30 stargate hostapd[29319]:    -P   PID file
Nov 18 12:04:30 stargate hostapd[29319]:    -K   include key data in debug messages
Nov 18 12:04:30 stargate hostapd[29319]:    -f   log output to debug file instead of stdout
Nov 18 12:04:30 stargate hostapd[29319]:    -T   record to Linux tracing in addition to logging
Nov 18 12:04:30 stargate hostapd[29319]:         (records all messages regardless of debug verbosity)
Nov 18 12:04:30 stargate hostapd[29319]:    -i   list of interface names to use
Nov 18 12:04:30 stargate hostapd[29319]:    -S   start all the interfaces synchronously
Nov 18 12:04:30 stargate hostapd[29319]:    -t   include timestamps in some debug messages
Nov 18 12:04:30 stargate hostapd[29319]:    -v   show hostapd version
Nov 18 12:04:30 stargate systemd[1]: hostapd.service: Control process exited, code=exited, status=1/FAILURE
░░ Subject: Unit process exited
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ An ExecStart= process belonging to unit hostapd.service has exited.
░░
░░ The process' exit code is 'exited' and its exit status is 1.
Nov 18 12:04:30 stargate systemd[1]: hostapd.service: Failed with result 'exit-code'.
░░ Subject: Unit failed
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ The unit hostapd.service has entered the 'failed' state with result 'exit-code'.
Nov 18 12:04:30 stargate systemd[1]: Failed to start hostapd.service - Access point and authentication server for Wi-Fi and Ethernet.
░░ Subject: A start job for unit hostapd.service has failed
░░ Defined-By: systemd
░░ Support: https://www.debian.org/support
░░
░░ A start job for unit hostapd.service has finished with a failure.
░░
░░ The job identifier is 224063 and the job result is failed.
lines 2262-2300/2300 (END)