# TODO

## Better SSH key management
* Split server and client configuration
* SSH certificates?

## Support Nix signing
* Implement signing all paths in the cache (when?)

## Improve GC
* Copy entire CSI stores to cache on an interval (Keep paths cache alive)
* Rewrite timegc to query dead paths before querying DB for regtime

## Building
* Wrap distributed building in a nicer "package"
* Better substitution configuration
* Implement speed factor

## Controller
* Rename cache to controller, integrate Kopf for additional future features.

## OverlayFS
* Implement OverlayFS write quota with eviction
