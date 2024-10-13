# OpenVPN Monitor

Simple script to monitor usage stats (received/sent bytes) of OpenVPN per user (name+ip+port) with easy setup and no dependencies (except bash, awk and nohup)

## Example

### Setup
Add next to config of OpenVPN (e.g. `/etc/openvpn/server/server.conf`):
```
status openvpn-status.log
status-version 2
```

### Launch Monitoring
```sh
nohup ./openvpn-monitor.sh --status-log=/etc/openvpn/server/openvpn-status.log --stats=/etc/openvpn/server/openvpn-stats.log &
```

Note: nohup.out is empty, log is printed to extra log file.

### Parse Stats

#### Received Mb
```sh
cat /etc/openvpn/server/openvpn-stats.log | grep <id> | awk -F '@' '{print $2}'|awk -F ',' '{s+=$1}END{print s/1024/1024}'
```

#### Sent Mb
```sh
cat /etc/openvpn/server/openvpn-stats.log | grep <id> | awk -F '@' '{print $2}'|awk -F ',' '{s+=$2}END{print s/1024/1024}'
```