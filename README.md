# zrpc
Zig binary RPC prototype

## Requirements
Download and verify Zig compiler:
```bash
./zig/download.sh  # Downloads Zig compiler
./zig/zig version  # Verify installation
```

## Build & Run

Build and run both components (in separate terminals):
```bash
./zig/zig build run-server
./zig/zig build run-client
```

## Features
- Binary protocol with fixed-size message headers
- Arena allocators for efficient memory management
- Type-safe serialization/deserialization

## Limitations
- Currently demonstrates single RPC method (add)
- Basic TCP transport layer without TLS
- Minimal error handling and recovery

## License
MIT License - See [LICENSE](LICENSE)