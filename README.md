# consul-elected

_WIP_

Yet another process manager, but integrated with Consul to use leader election
and attempt to make sure only one instance gets run at a time.

Usage: `consul-elected -s [server:port] -k [key] -c [command]`

Command will be run only if lock is acquired on the key.