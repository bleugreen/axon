# Connect your agent

Axon exposes its tools through the [Model Context Protocol](https://modelcontextprotocol.io/). Your agent launches `axon mcp`, and that small stdio process forwards tool calls to the local Axon service.

Make sure `axon status` reports that the service is running and Accessibility is granted, then register Axon with your client.

## Claude Code

```sh
claude mcp add axon -- axon mcp
```

## Codex

```sh
codex mcp add axon -- axon mcp
```

## Other MCP clients

Configure a local stdio server with `axon` as the command and `mcp` as its only argument:

```json
{
  "command": "axon",
  "args": ["mcp"]
}
```

An absolute path to `axon` also works when your client does not inherit your shell's `PATH`.

After registration, ask your agent to list running apps or call `look`. Axon will return the accessibility state it can inspect. See [Tools](tool-surface.md) for the complete surface.

If you need the registration commands again, run `axon` with no arguments. Once Accessibility is trusted, setup prints them each time.
