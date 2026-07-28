# Foreground Revalidation Design

Current source anchors are against HEAD `f49382092727ebb7b9407dcc771136287da9d444`.

## Summary

A foregrounded phone must not trust a stale `.connected` tunnel just because the state machine still says
it is connected. `TunnelManager.revalidateConnectedTunnelForForeground()` probes the active epoch and drives
a reconnect on failure, both foreground sites route through `SolstoneSwiftApp.revalidateThenRequestDrain`,
and the first probe of a new connection now starts from the healthy interval.

## AC8

> AC8 fault-reason propagation is routed to L2/spl-swift, which is in flight in the same arc.
> `TunnelSession` exposes no reason-bearing `disconnect()`, so this ship records app-detected probe
> failure at the app layer and does not attach that reason to SPL teardown. The consuming change lands
> once L2 ships a reason-bearing teardown API.

## Residual

> Accepted residual: worst-case foreground detection latency on the relay path is one healthy probe
> interval plus the probe timeout (~15s x 1.25 + 3s ~= 22s), and detection while suspended remains zero.
> That is the accepted price of the anti-ask, not a miss.

## Not Done Here

Relay keepalive stays off, and background execution was explicitly not added.
