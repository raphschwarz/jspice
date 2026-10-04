import Foundation
import JSpiceAutomation

// `jspice-mcp`: a Model Context Protocol server over standard input and output, so an AI agent can build, simulate and
// measure circuits with the JSpice engine. Add it to an MCP client (Claude Desktop, Claude Code) as a stdio server.
let server = MCPServer(session: CircuitSession())
server.runOnStandardIO()
