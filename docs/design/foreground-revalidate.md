# Foreground Revalidation Design

Source anchors are against the commit that introduced this change.

## Summary

A foregrounded phone must not trust a stale `.connected` tunnel just because the state machine still says
it is connected. `TunnelManager.revalidateConnectedTunnelForForeground()` probes the active epoch and drives
a reconnect on failure, both foreground sites route through `SolstoneSwiftApp.revalidateThenRequestDrain`,
and the first probe of a new connection now starts from the healthy interval.

## Teardown fault reasons are not attached here

`TunnelSession` exposes no reason-bearing `disconnect()`: it always tears down as a normal shutdown, so an
upload parked mid-response sees a clean end-of-stream rather than an error, even on a teardown whose whole
premise is that the tunnel is dead.

Carrying a fault reason across that boundary cannot be done from this repository. This change therefore
records app-detected probe failure at the app layer only, and does not attach that reason to the transport
teardown. The consuming change lands once the transport package offers a reason-bearing teardown API.

## Residual

Worst-case foreground detection latency on the relay path is one healthy probe interval plus the probe
timeout (~15s x 1.25 + 3s ~= 22s), and detection while suspended remains zero. That is the accepted price
of leaving relay keepalive off, not an oversight.

## Not Done Here

Relay keepalive stays off, and background execution was explicitly not added.
